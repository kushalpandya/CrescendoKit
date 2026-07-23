/*
 * ctaglib.cpp - Implementation of the C-API shim declared in ctaglib.h.
 *
 * Compiled by Scripts/build-taglib.sh and merged with a static libtag.a into
 * the static libCTagLib.a that the Crescendo engine folds into
 * Crescendo.framework at archive time. Parses one file into a shim-owned
 * `ctaglib_metadata` and exposes borrowed views of the copied-out values.
 *
 * Most tags come from TagLib's unified PropertyMap (one normalized key space
 * across all container formats); audio properties, pictures, and the ID3v2
 * POPM rating need format-specific access via dynamic_cast. dynamic_cast is
 * safe here: the shim and TagLib are statically linked into the same Mach-O
 * image (today Crescendo.framework), so RTTI always resolves intra-image
 * despite hidden visibility.
 *
 * Every `extern "C"` entry point that touches untrusted data is wrapped in
 * try/catch: a C++ exception unwinding across the C boundary is undefined
 * behavior, so failures are caught and reported as a null/zero sentinel.
 */

#include "ctaglib.h"

#include <atomic>
#include <memory>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "fileref.h"
#include "tfile.h"
#include "audioproperties.h"
#include "tstring.h"
#include "tstringlist.h"
#include "tpropertymap.h"
#include "tvariant.h"
#include "tbytevector.h"
#include "tlist.h"
#include "tdebuglistener.h"

// TagLib's tdebug.h is internal and not installed with the public headers,
// so declare the debug-channel entry point directly (signature mirrored from
// taglib/toolkit/tdebug.h). The definition exists in our libtag.a because
// build-taglib.sh compiles TagLib with -DTRACE_IN_RELEASE; the static link
// resolves it despite hidden visibility.
namespace TagLib {
void debug(const String &s);
} // namespace TagLib

// Format-specific properties, for codec name + bit depth.
#include "flacproperties.h"
#include "mp4properties.h"
#include "mpegproperties.h"
#include "vorbisproperties.h"
#include "opusproperties.h"
#include "wavproperties.h"
#include "aiffproperties.h"
#include "apeproperties.h"
#include "wavpackproperties.h"
#include "trueaudioproperties.h"
#include "mpcproperties.h"
#include "dsfproperties.h"
#include "dsdiffproperties.h"
#include "asfproperties.h"

// ID3v2 POPM rating (MP3 and other ID3v2 carriers).
#include "mpegfile.h"
#include "id3v2tag.h"
#include "popularimeterframe.h"

// ID3v2 chapters (CHAP/CTOC) and the frame types nested inside them.
#include "chapterframe.h"
#include "tableofcontentsframe.h"
#include "textidentificationframe.h"
#include "attachedpictureframe.h"
#include "urllinkframe.h"
#include "tpicturetype.h"

namespace {

// One embedded picture: the encoded bytes plus its MIME type, TagLib's
// canonical type string ("Front Cover", ...), and free-text description.
struct Picture {
    std::vector<unsigned char> data;
    std::string mime;
    std::string type;
    std::string description;
};

// One ID3v2 chapter (CHAP frame), as copied out of the tag: its start/end
// in milliseconds (-1 = the frame recorded no usable value) and the bounded
// nested values. Times are raw and unordered here; the Swift normalizer
// owns sorting and end synthesis. (CTOC resolution reads element IDs off
// the live frames and finishes before these are built, so no ID is kept.)
struct Chapter {
    int64_t startMs = -1;
    int64_t endMs = -1;
    std::string title;
    std::string url;
    bool hasPicture = false;
    Picture picture;
};

// Converts a TagLib::String to a UTF-8 std::string.
std::string toUtf8(const TagLib::String &s) {
    return s.to8Bit(true);
}

// Derives the codec/format name, bit depth, and lossless flag from the concrete
// AudioProperties subclass - i.e. from the actually-decoded codec, not the file
// extension. This is what lets us distinguish ALAC from AAC inside .m4a, WMA
// Lossless from lossy WMA, and lossless WavPack from its hybrid-lossy mode.
//   lossless: 1 = lossless, 0 = lossy, -1 = unknown.
void extractFormatInfo(const TagLib::AudioProperties *props,
                       bool &hasCodec, std::string &codec, int &bitsPerSample, int &lossless) {
    hasCodec = false;
    codec.clear();
    bitsPerSample = 0;
    lossless = -1;
    if (props == nullptr) {
        return;
    }

    if (const auto *p = dynamic_cast<const TagLib::FLAC::Properties *>(props)) {
        codec = "flac";
        bitsPerSample = p->bitsPerSample();
        lossless = 1;
    } else if (const auto *p = dynamic_cast<const TagLib::MP4::Properties *>(props)) {
        const bool alac = p->codec() == TagLib::MP4::Properties::ALAC;
        codec = alac ? "alac" : "aac";
        bitsPerSample = p->bitsPerSample();
        lossless = alac ? 1 : 0;
    } else if (dynamic_cast<const TagLib::MPEG::Properties *>(props) != nullptr) {
        codec = "mp3";
        lossless = 0;
    } else if (dynamic_cast<const TagLib::Ogg::Vorbis::Properties *>(props) != nullptr) {
        codec = "vorbis";
        lossless = 0;
    } else if (dynamic_cast<const TagLib::Ogg::Opus::Properties *>(props) != nullptr) {
        codec = "opus";
        lossless = 0;
    } else if (const auto *p = dynamic_cast<const TagLib::RIFF::WAV::Properties *>(props)) {
        codec = "wav";
        bitsPerSample = p->bitsPerSample();
        lossless = 1;
    } else if (const auto *p = dynamic_cast<const TagLib::RIFF::AIFF::Properties *>(props)) {
        codec = "aiff";
        bitsPerSample = p->bitsPerSample();
        lossless = 1;
    } else if (const auto *p = dynamic_cast<const TagLib::APE::Properties *>(props)) {
        codec = "ape";
        bitsPerSample = p->bitsPerSample();
        lossless = 1;
    } else if (const auto *p = dynamic_cast<const TagLib::WavPack::Properties *>(props)) {
        codec = "wavpack";
        bitsPerSample = p->bitsPerSample();
        lossless = p->isLossless() ? 1 : 0; // WavPack has a hybrid lossy mode
    } else if (const auto *p = dynamic_cast<const TagLib::TrueAudio::Properties *>(props)) {
        codec = "tta";
        bitsPerSample = p->bitsPerSample();
        lossless = 1;
    } else if (dynamic_cast<const TagLib::MPC::Properties *>(props) != nullptr) {
        codec = "musepack";
        lossless = 0;
    } else if (const auto *p = dynamic_cast<const TagLib::DSF::Properties *>(props)) {
        codec = "dsf";
        bitsPerSample = p->bitsPerSample();
        lossless = 1;
    } else if (const auto *p = dynamic_cast<const TagLib::DSDIFF::Properties *>(props)) {
        codec = "dsdiff";
        bitsPerSample = p->bitsPerSample();
        lossless = 1;
    } else if (const auto *p = dynamic_cast<const TagLib::ASF::Properties *>(props)) {
        codec = "wma";
        lossless = (p->codec() == TagLib::ASF::Properties::WMA9Lossless) ? 1 : 0;
    }

    hasCodec = !codec.empty();
}

// Reads the ID3v2 POPM rating byte (0-255) if the file carries one.
void extractRating(TagLib::File *file, bool &hasRating, int &rating) {
    hasRating = false;
    rating = 0;

    auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(file);
    if (mpeg == nullptr || !mpeg->hasID3v2Tag()) {
        return;
    }
    const TagLib::ID3v2::Tag *tag = mpeg->ID3v2Tag();
    if (tag == nullptr) {
        return;
    }
    const TagLib::ID3v2::FrameList &frames = tag->frameList("POPM");
    if (frames.isEmpty()) {
        return;
    }
    const auto *popm = dynamic_cast<const TagLib::ID3v2::PopularimeterFrame *>(frames.front());
    if (popm == nullptr) {
        return;
    }
    rating = popm->rating();
    hasRating = true;
}

} // namespace

// The opaque handle. Holds copies of every value so that accessors never reach
// back into TagLib objects (which are destroyed when the read returns).
struct ctaglib_metadata {
    double lengthSeconds = 0.0;
    int sampleRate = 0;
    int channels = 0;
    int bitrateKbps = 0;
    int bitsPerSample = 0;

    bool hasCodec = false;
    std::string codec;
    int lossless = -1; // 1 = lossless, 0 = lossy, -1 = unknown

    // The full TagLib PropertyMap, as ordered (key, [values]) pairs.
    std::vector<std::pair<std::string, std::vector<std::string>>> tags;

    std::vector<Picture> pictures;

    std::vector<Chapter> chapters;

    bool hasRating = false;
    int rating = 0;
};

namespace {

// Defensive bounds for untrusted input. A player scans whole libraries, so a
// single crafted or corrupt file must not be able to make the shim copy out
// unbounded memory. Real files sit far below all of these, so the caps only
// ever trip on pathological input. Reads stay raw and unnormalized otherwise:
// the caps drop excess, they do not transform.
constexpr size_t maxTagCount = 4096;                  // distinct property keys
constexpr size_t maxValuesPerTag = 1024;              // values under one key
constexpr size_t maxValueLength = 1024 * 1024;        // source chars per value
constexpr size_t maxPictureCount = 8;                 // attached pictures
// Matches the Swift reader's own per-picture cap exactly: copying more here
// would only hand Swift bytes it is guaranteed to reject (its cap is also
// enforced Swift-side so the protection holds against older shim builds).
constexpr size_t maxPictureBytes = 24 * 1024 * 1024;  // bytes per picture
// Chapter bounds, mirrored by the Swift normalizer: a crafted podcast file
// must not copy out unbounded chapters or smuggle unbounded artwork through
// thousands of individually plausible nested APIC frames.
constexpr size_t maxChapterCount = 2000;                        // chapters per file
constexpr size_t maxChapterArtworkTotal = 64 * 1024 * 1024;     // all chapter art together

// Copies one picture's fields into `out` under the shared byte bound, so
// ordinary attached pictures and nested chapter APIC frames can never
// diverge in conversion or caps. `budget` is the caller's remaining
// aggregate byte budget (pass a large value for the ordinary path, whose
// aggregate is bounded by maxPictureCount instead); a picture that is
// empty, over the per-picture cap, or over the remaining budget is refused.
// The string fields obey the shared value-length cap (checked on the source
// string, before conversion); an oversized one is dropped, not the picture.
// Returns whether `out` was filled (and `budget` debited).
bool copyPicture(const TagLib::ByteVector &data,
                 const TagLib::String &mime,
                 const TagLib::String &type,
                 const TagLib::String &description,
                 size_t &budget,
                 Picture &out) {
    if (data.isEmpty() || data.size() > maxPictureBytes || data.size() > budget) {
        return false;
    }
    budget -= data.size();
    out.data.assign(
        reinterpret_cast<const unsigned char *>(data.data()),
        reinterpret_cast<const unsigned char *>(data.data()) + data.size());
    // The value cap is enforced on the RETAINED UTF-8 bytes as well as the
    // source units (UTF-8 expands up to 3x the UTF-16 unit count).
    const auto bounded = [](const TagLib::String &value) -> std::string {
        if (value.size() > maxValueLength) {
            return std::string();
        }
        std::string utf8 = toUtf8(value);
        return utf8.size() > maxValueLength ? std::string() : utf8;
    };
    out.mime = bounded(mime);
    out.type = bounded(type);
    out.description = bounded(description);
    return true;
}

// Copies the unified tag dictionary out of `file` into shim-owned storage,
// bounded by the caps above. Shared by the full and tags-only reads so the
// two can never diverge. An oversized individual value is dropped without
// converting it (the length check is on the source string, so a pathological
// value never forces a large UTF-8 conversion); a key left with no values is
// itself dropped rather than surfaced empty.
void copyProperties(TagLib::File *file, ctaglib_metadata *meta) {
    const TagLib::PropertyMap properties = file->properties();
    for (auto it = properties.begin(); it != properties.end(); ++it) {
        if (meta->tags.size() >= maxTagCount) {
            break;
        }
        std::vector<std::string> values;
        const TagLib::StringList &list = it->second;
        for (auto vit = list.begin(); vit != list.end(); ++vit) {
            if (values.size() >= maxValuesPerTag) {
                break;
            }
            if ((*vit).size() > maxValueLength) {
                continue;
            }
            // The cap also binds the retained UTF-8 bytes (UTF-8 expands up
            // to 3x the source units); the Swift side enforces the same
            // byte bound, so dropping here changes no observable value.
            std::string utf8 = toUtf8(*vit);
            if (utf8.size() > maxValueLength) {
                continue;
            }
            values.push_back(std::move(utf8));
        }
        if (!values.empty()) {
            meta->tags.emplace_back(toUtf8(it->first), std::move(values));
        }
    }
}

// Reads the ID3v2 chapter set (CHAP frames, ordered by a valid top-level
// ordered CTOC when present) out of an MPEG file into shim-owned storage.
//
// TagLib owns every parsing concern (frame sizes, unsynchronization,
// extended headers, encodings, nested-frame parsing, malformed frames);
// this copies bounded values out of its concrete frame types. Limited to
// MPEG (MP3) files - the only fixture-backed ID3v2 chapter carrier - and
// a no-op for everything else. A malformed frame degrades to skipped or
// partial chapter data, never a thrown exception (the caller's exception
// boundary is the backstop).
void extractChapters(TagLib::File *file, ctaglib_metadata *meta) {
    auto *mpeg = dynamic_cast<TagLib::MPEG::File *>(file);
    if (mpeg == nullptr || !mpeg->hasID3v2Tag()) {
        return;
    }
    const TagLib::ID3v2::Tag *tag = mpeg->ID3v2Tag();
    if (tag == nullptr) {
        return;
    }

    // Valid CHAP frames in source order, capped up front: a hostile tag can
    // hold hundreds of thousands of minimal CHAP frames, and everything
    // below (CTOC resolution, copy-out) must stay bounded by the cap, not
    // by the file.
    std::vector<const TagLib::ID3v2::ChapterFrame *> source;
    const TagLib::ID3v2::FrameList &chapFrames = tag->frameList("CHAP");
    for (auto it = chapFrames.begin(); it != chapFrames.end(); ++it) {
        if (source.size() >= maxChapterCount) {
            break;
        }
        if (const auto *chap = dynamic_cast<const TagLib::ID3v2::ChapterFrame *>(*it)) {
            source.push_back(chap);
        }
    }
    if (source.empty()) {
        return;
    }

    // Resolve playback order through the top-level CTOC when the tag has a
    // valid ordered one: its child element IDs pick CHAP frames first, and
    // valid CHAP frames it omits are appended in source order. Without one,
    // source order stands. (Chronological sorting happens in Swift.)
    //
    // Resolution is via an id -> unused-source-indices map, and the child
    // walk stops once every CHAP is matched or a bounded number of children
    // has been inspected: a hostile CTOC can hold millions of child IDs, and
    // a per-child linear scan of the CHAP list would otherwise turn one
    // file into hours of CPU on an uncancellable read.
    std::vector<const TagLib::ID3v2::ChapterFrame *> ordered;
    std::vector<bool> used(source.size(), false);
    const TagLib::ID3v2::TableOfContentsFrame *toc =
        TagLib::ID3v2::TableOfContentsFrame::findTopLevel(tag);
    if (toc != nullptr && toc->isOrdered()) {
        // Element IDs are tiny in practice ("chp1"); an ID past this bound
        // is skipped before OUR byte copy (the std::string below), keeping
        // routing storage bounded at maxChapterCount x maxElementIdBytes
        // (~0.5 MB) no matter how large a crafted tag's IDs are. The
        // elementID()/childElements() accessors themselves are cheap:
        // TagLib's ByteVector/List are implicitly shared, so those calls
        // are refcount copies of data the parsed tag already holds, not
        // fresh allocations. A skipped CHAP simply falls to the
        // unreferenced source-order append below.
        constexpr size_t maxElementIdBytes = 256;
        // Reverse-filled so pop_back yields the FIRST unused CHAP with that
        // element ID (duplicate IDs resolve in source order).
        std::unordered_map<std::string, std::vector<size_t>> unusedById;
        for (size_t i = source.size(); i-- > 0;) {
            const TagLib::ByteVector id = source[i]->elementID();
            // Empty IDs are skipped: a malformed frame's empty ByteVector
            // may report a null data() pointer, and constructing a
            // std::string from one is undefined even at length zero (an
            // empty ID also cannot meaningfully match a CTOC child).
            if (id.isEmpty() || id.size() > maxElementIdBytes) {
                continue;
            }
            unusedById[std::string(id.data(), id.size())].push_back(i);
        }
        // (TagLib materialized the child list when it parsed the CTOC frame;
        // the size check below only bounds OUR copies, not that parse.)
        const TagLib::ByteVectorList children = toc->childElements();
        const size_t maxChildInspections = maxChapterCount * 4;
        size_t inspected = 0;
        for (auto it = children.begin(); it != children.end(); ++it) {
            if (ordered.size() >= source.size() || inspected >= maxChildInspections) {
                break;
            }
            ++inspected;
            // Same empty-ID guard as the map build: a null data() pointer
            // must never reach the std::string constructor.
            if (it->isEmpty() || it->size() > maxElementIdBytes) {
                continue;
            }
            auto match = unusedById.find(std::string(it->data(), it->size()));
            if (match == unusedById.end() || match->second.empty()) {
                continue;
            }
            const size_t index = match->second.back();
            match->second.pop_back();
            used[index] = true;
            ordered.push_back(source[index]);
        }
    }
    for (size_t i = 0; i < source.size(); ++i) {
        if (!used[i]) {
            ordered.push_back(source[i]);
        }
    }

    // Nested frames are scanned (not just the first taken) up to this many
    // per frame ID, so an empty or oversized first frame cannot hide a
    // later usable one, while a hostile tag nesting thousands stays cheap.
    constexpr size_t maxNestedFrameScan = 8;

    // Converts a nested text/URL value under the shared value-length cap.
    // Checked TWICE: on the source string (so a huge value never converts
    // at all) and on the converted UTF-8 bytes (UTF-8 expands up to 3x the
    // UTF-16 unit count, and the retained bound is a byte bound). An
    // over-cap value is skipped; the chapter survives.
    const auto boundedUtf8 = [](const TagLib::String &value) -> std::string {
        if (value.size() > maxValueLength) {
            return std::string();
        }
        std::string utf8 = toUtf8(value);
        if (utf8.size() > maxValueLength) {
            return std::string();
        }
        return utf8;
    };
    // The first usable nested text value of the given frame ID, or empty.
    // The frame's individual fields are summed BEFORE toString(), which
    // concatenates them into a fresh allocation - an over-cap frame is
    // rejected without ever building that concatenation.
    const auto firstUsableText = [&boundedUtf8, maxNestedFrameScan](
        const TagLib::ID3v2::ChapterFrame *chap, const char *frameId) -> std::string {
        const TagLib::ID3v2::FrameList &frames = chap->embeddedFrameList(frameId);
        size_t scanned = 0;
        for (auto it = frames.begin(); it != frames.end() && scanned < maxNestedFrameScan; ++it, ++scanned) {
            if (const auto *text = dynamic_cast<const TagLib::ID3v2::TextIdentificationFrame *>(*it)) {
                const TagLib::StringList fields = text->fieldList();
                size_t totalUnits = 0;
                for (auto fit = fields.begin(); fit != fields.end() && totalUnits <= maxValueLength; ++fit) {
                    // toString() joins fields with a one-unit separator;
                    // count those too, so the estimate never undershoots
                    // the concatenation it is guarding against. The loop
                    // bails past the cap, so the sum cannot overflow.
                    if (fit != fields.begin()) {
                        totalUnits += 1;
                    }
                    totalUnits += fit->size();
                }
                if (totalUnits > maxValueLength) {
                    continue;
                }
                std::string value = boundedUtf8(text->toString());
                if (!value.empty()) {
                    return value;
                }
            }
        }
        return std::string();
    };

    size_t artworkBudget = maxChapterArtworkTotal;
    for (const TagLib::ID3v2::ChapterFrame *chap : ordered) {
        if (meta->chapters.size() >= maxChapterCount) {
            break;
        }
        Chapter chapter;

        // CHAP times are unsigned 32-bit milliseconds. 0xFFFFFFFF is the
        // conventional "unknown" sentinel (the spec reserves it for the
        // byte offsets, but writers emit it for times too); map it to the
        // absent sentinel rather than surfacing a 49-day timestamp.
        const unsigned int startMs = chap->startTime();
        const unsigned int endMs = chap->endTime();
        chapter.startMs = (startMs == 0xFFFFFFFFU) ? -1 : static_cast<int64_t>(startMs);
        chapter.endMs = (endMs == 0xFFFFFFFFU) ? -1 : static_cast<int64_t>(endMs);

        // Title: nested TIT2, falling back to TIT3 (subtitle).
        for (const char *titleId : {"TIT2", "TIT3"}) {
            chapter.title = firstUsableText(chap, titleId);
            if (!chapter.title.empty()) {
                break;
            }
        }

        // Link: the first usable nested WXXX (user URL frame).
        {
            const TagLib::ID3v2::FrameList &links = chap->embeddedFrameList("WXXX");
            size_t scanned = 0;
            for (auto it = links.begin(); it != links.end() && scanned < maxNestedFrameScan; ++it, ++scanned) {
                if (const auto *link = dynamic_cast<const TagLib::ID3v2::UserUrlLinkFrame *>(*it)) {
                    chapter.url = boundedUtf8(link->url());
                    if (!chapter.url.empty()) {
                        break;
                    }
                }
            }
        }

        // Artwork: the first nested APIC the copy helper accepts, through
        // the same conversion and byte bounds as ordinary attached
        // pictures, plus the aggregate budget - a refused frame (empty,
        // oversized, over budget) does not hide a later acceptable one.
        {
            const TagLib::ID3v2::FrameList &pictures = chap->embeddedFrameList("APIC");
            size_t scanned = 0;
            for (auto it = pictures.begin();
                 it != pictures.end() && scanned < maxNestedFrameScan && !chapter.hasPicture;
                 ++it, ++scanned) {
                if (const auto *apic = dynamic_cast<const TagLib::ID3v2::AttachedPictureFrame *>(*it)) {
                    chapter.hasPicture = copyPicture(
                        apic->picture(),
                        apic->mimeType(),
                        TagLib::Utils::pictureTypeToString(apic->type()),
                        apic->description(),
                        artworkBudget,
                        chapter.picture);
                }
            }
        }

        meta->chapters.push_back(std::move(chapter));
    }
}

// The single read body behind every public read variant: parses the file
// once and extracts only the sections selected in `options`. The FileRef is
// constructed without the audio-properties parse when they were not asked
// for; everything else TagLib reads is dictated by the container format, so
// the options gate the copy-out (and its allocations), not the file I/O.
ctaglib_metadata *readWithOptions(const char *path, uint32_t options) {
    if (path == nullptr) {
        return nullptr;
    }
    try {
        const bool wantProperties = (options & CTAGLIB_READ_AUDIO_PROPERTIES) != 0;
        // FileRef picks the right parser from the file's content/extension.
        TagLib::FileRef ref(path, wantProperties);
        TagLib::File *file = ref.file();
        if (ref.isNull() || file == nullptr) {
            return nullptr;
        }

        // unique_ptr so a mid-extraction throw (e.g. bad_alloc while copying
        // hostile values) releases everything copied so far instead of
        // leaking it through the catch below.
        auto meta = std::make_unique<ctaglib_metadata>();

        if (wantProperties) {
            if (const TagLib::AudioProperties *props = ref.audioProperties()) {
                meta->lengthSeconds = props->lengthInMilliseconds() / 1000.0;
                meta->sampleRate = props->sampleRate();
                meta->channels = props->channels();
                meta->bitrateKbps = props->bitrate();
                extractFormatInfo(props, meta->hasCodec, meta->codec, meta->bitsPerSample, meta->lossless);
            }
        }

        if ((options & CTAGLIB_READ_TAGS) != 0) {
            copyProperties(file, meta.get());
        }

        // Attached pictures via the unified complex-properties API. Skip any
        // picture larger than the byte cap and stop after the count cap: cover
        // art is far smaller and far fewer in practice, and a corrupt or hostile
        // file encountered during a bulk scan must not be able to make us copy
        // out enormous or unboundedly many buffers.
        if ((options & CTAGLIB_READ_PICTURES) != 0) {
            const TagLib::List<TagLib::VariantMap> pictures = file->complexProperties("PICTURE");
            // The ordinary path's aggregate is bounded by the count cap, so
            // its per-call budget is effectively the per-picture cap alone.
            size_t budget = maxPictureCount * maxPictureBytes;
            for (auto it = pictures.begin(); it != pictures.end(); ++it) {
                if (meta->pictures.size() >= maxPictureCount) {
                    break;
                }
                const TagLib::VariantMap &map = *it;
                Picture picture;
                if (!copyPicture(map.value("data").value<TagLib::ByteVector>(),
                                 map.value("mimeType").value<TagLib::String>(),
                                 map.value("pictureType").value<TagLib::String>(),
                                 map.value("description").value<TagLib::String>(),
                                 budget,
                                 picture)) {
                    continue;
                }
                meta->pictures.push_back(std::move(picture));
            }
        }

        if ((options & CTAGLIB_READ_RATING) != 0) {
            extractRating(file, meta->hasRating, meta->rating);
        }

        if ((options & CTAGLIB_READ_CHAPTERS) != 0) {
            extractChapters(file, meta.get());
        }

        return meta.release();
    } catch (...) {
        // Any parser failure on untrusted input becomes a clean NULL.
        return nullptr;
    }
}

} // namespace

extern "C" {

ctaglib_metadata *ctaglib_read(const char *path) {
    return readWithOptions(
        path,
        CTAGLIB_READ_AUDIO_PROPERTIES | CTAGLIB_READ_TAGS | CTAGLIB_READ_PICTURES | CTAGLIB_READ_RATING);
}

ctaglib_metadata *ctaglib_read_tags(const char *path) {
    return readWithOptions(path, CTAGLIB_READ_TAGS);
}

ctaglib_metadata *ctaglib_read_with(const char *path, uint32_t options) {
    return readWithOptions(path, options);
}

void ctaglib_metadata_free(ctaglib_metadata *meta) {
    delete meta;
}

double ctaglib_length_seconds(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->lengthSeconds : 0.0;
}

int ctaglib_sample_rate(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->sampleRate : 0;
}

int ctaglib_channels(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->channels : 0;
}

int ctaglib_bitrate_kbps(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->bitrateKbps : 0;
}

int ctaglib_bits_per_sample(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->bitsPerSample : 0;
}

int ctaglib_is_lossless(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->lossless : -1;
}

const char *ctaglib_codec(const ctaglib_metadata *meta, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || !meta->hasCodec) {
        *out_len = 0;
        return nullptr;
    }
    *out_len = meta->codec.size();
    return meta->codec.data();
}

size_t ctaglib_tag_count(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->tags.size() : 0;
}

const char *ctaglib_tag_key(const ctaglib_metadata *meta, size_t i, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->tags.size()) {
        *out_len = 0;
        return nullptr;
    }
    const std::string &key = meta->tags[i].first;
    *out_len = key.size();
    return key.data();
}

size_t ctaglib_tag_value_count(const ctaglib_metadata *meta, size_t i) {
    if (meta == nullptr || i >= meta->tags.size()) {
        return 0;
    }
    return meta->tags[i].second.size();
}

const char *ctaglib_tag_value(const ctaglib_metadata *meta, size_t i, size_t j, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->tags.size() || j >= meta->tags[i].second.size()) {
        *out_len = 0;
        return nullptr;
    }
    const std::string &value = meta->tags[i].second[j];
    *out_len = value.size();
    return value.data();
}

size_t ctaglib_picture_count(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->pictures.size() : 0;
}

const unsigned char *ctaglib_picture_data(const ctaglib_metadata *meta, size_t i, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->pictures.size()) {
        *out_len = 0;
        return nullptr;
    }
    const std::vector<unsigned char> &data = meta->pictures[i].data;
    *out_len = data.size();
    return data.data();
}

const char *ctaglib_picture_mime(const ctaglib_metadata *meta, size_t i, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->pictures.size() || meta->pictures[i].mime.empty()) {
        *out_len = 0;
        return nullptr;
    }
    const std::string &mime = meta->pictures[i].mime;
    *out_len = mime.size();
    return mime.data();
}

const char *ctaglib_picture_type(const ctaglib_metadata *meta, size_t i, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->pictures.size() || meta->pictures[i].type.empty()) {
        *out_len = 0;
        return nullptr;
    }
    const std::string &type = meta->pictures[i].type;
    *out_len = type.size();
    return type.data();
}

const char *ctaglib_picture_description(const ctaglib_metadata *meta, size_t i, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->pictures.size() || meta->pictures[i].description.empty()) {
        *out_len = 0;
        return nullptr;
    }
    const std::string &description = meta->pictures[i].description;
    *out_len = description.size();
    return description.data();
}

int ctaglib_has_rating(const ctaglib_metadata *meta) {
    return (meta != nullptr && meta->hasRating) ? 1 : 0;
}

int ctaglib_rating(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->rating : 0;
}

size_t ctaglib_chapter_count(const ctaglib_metadata *meta) {
    return meta != nullptr ? meta->chapters.size() : 0;
}

int64_t ctaglib_chapter_start_ms(const ctaglib_metadata *meta, size_t i) {
    if (meta == nullptr || i >= meta->chapters.size()) {
        return -1;
    }
    return meta->chapters[i].startMs;
}

int64_t ctaglib_chapter_end_ms(const ctaglib_metadata *meta, size_t i) {
    if (meta == nullptr || i >= meta->chapters.size()) {
        return -1;
    }
    return meta->chapters[i].endMs;
}

const char *ctaglib_chapter_title(const ctaglib_metadata *meta, size_t i, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->chapters.size() || meta->chapters[i].title.empty()) {
        *out_len = 0;
        return nullptr;
    }
    const std::string &title = meta->chapters[i].title;
    *out_len = title.size();
    return title.data();
}

const char *ctaglib_chapter_url(const ctaglib_metadata *meta, size_t i, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->chapters.size() || meta->chapters[i].url.empty()) {
        *out_len = 0;
        return nullptr;
    }
    const std::string &url = meta->chapters[i].url;
    *out_len = url.size();
    return url.data();
}

const unsigned char *ctaglib_chapter_picture_data(const ctaglib_metadata *meta, size_t i, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->chapters.size() || !meta->chapters[i].hasPicture) {
        *out_len = 0;
        return nullptr;
    }
    const std::vector<unsigned char> &data = meta->chapters[i].picture.data;
    *out_len = data.size();
    return data.data();
}

const char *ctaglib_chapter_picture_mime(const ctaglib_metadata *meta, size_t i, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->chapters.size() || !meta->chapters[i].hasPicture ||
        meta->chapters[i].picture.mime.empty()) {
        *out_len = 0;
        return nullptr;
    }
    const std::string &mime = meta->chapters[i].picture.mime;
    *out_len = mime.size();
    return mime.data();
}

const char *ctaglib_chapter_picture_type(const ctaglib_metadata *meta, size_t i, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->chapters.size() || !meta->chapters[i].hasPicture ||
        meta->chapters[i].picture.type.empty()) {
        *out_len = 0;
        return nullptr;
    }
    const std::string &type = meta->chapters[i].picture.type;
    *out_len = type.size();
    return type.data();
}

const char *ctaglib_chapter_picture_description(const ctaglib_metadata *meta, size_t i, size_t *out_len) {
    if (out_len == nullptr) {
        return nullptr;
    }
    if (meta == nullptr || i >= meta->chapters.size() || !meta->chapters[i].hasPicture ||
        meta->chapters[i].picture.description.empty()) {
        *out_len = 0;
        return nullptr;
    }
    const std::string &description = meta->chapters[i].picture.description;
    *out_len = description.size();
    return description.data();
}

} // extern "C"

namespace {

// The installed sink. Atomic because reads run (and therefore emit) on any
// thread while the callback is installed once from another; the log path
// itself takes no locks.
std::atomic<ctaglib_log_callback> logCallback{nullptr};

// Adapts TagLib's listener interface to the C callback: converts to UTF-8,
// trims the trailing newline TagLib appends, and forwards. A message
// arriving while the callback is being cleared is dropped by the load.
class CallbackDebugListener : public TagLib::DebugListener {
public:
    void printMessage(const TagLib::String &msg) override {
        const ctaglib_log_callback callback = logCallback.load(std::memory_order_acquire);
        if (callback == nullptr) {
            return;
        }
        const std::string utf8 = toUtf8(msg);
        size_t length = utf8.size();
        while (length > 0 && (utf8[length - 1] == '\n' || utf8[length - 1] == '\r')) {
            --length;
        }
        if (length == 0) {
            return;
        }
        callback(utf8.data(), length);
    }
};

CallbackDebugListener bridgeListener;

} // namespace

extern "C" {

void ctaglib_set_log_callback(ctaglib_log_callback callback) {
    logCallback.store(callback, std::memory_order_release);
    // NULL restores TagLib's default stderr listener (setDebugListener's
    // documented null behavior).
    TagLib::setDebugListener(callback != nullptr ? &bridgeListener : nullptr);
}

void ctaglib_emit_debug(const char *message) {
    if (message == nullptr) {
        return;
    }
    TagLib::debug(TagLib::String(message, TagLib::String::UTF8));
}

} // extern "C"
