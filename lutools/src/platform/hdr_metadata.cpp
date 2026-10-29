#include "platform/hdr_metadata.h"
#include "platform/hdr_image.h"
#include <lcms2.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstring>
#include <map>
#include <limits>
#include <set>
#include <sstream>
#include <locale>
#include <image_io/xml/xml_reader.h>
#include <image_io/xml/xml_handler.h>
#include <image_io/xml/xml_element_rules.h>

namespace sony2fuji::hdr {
namespace {
[[noreturn]] void invalid() {
    throw Error(SONY2FUJI_STATUS_PROCESSING_ERROR,SONY2FUJI_HDR_REASON_MALFORMED_AUX,
        SONY2FUJI_HDR_FIELD_SOURCE,"Malformed image capture metadata");
}
struct Segment { uint8_t marker; const uint8_t* data; size_t size; };
std::vector<Segment> segments(const void* data,size_t size) {
    const auto* p=static_cast<const uint8_t*>(data);
    if (size<4 || p[0]!=255 || p[1]!=0xd8) invalid();
    std::vector<Segment> output;
    for (size_t at=2;at<size;) {
        if (p[at++]!=255) invalid();
        while (at<size && p[at]==255) ++at;
        if (at==size) invalid();
        const uint8_t marker=p[at++];
        if (marker==0xd9) return output;
        if (!marker || marker==0xd8 || (marker>=0xd0 && marker<=0xd7) || size-at<2) invalid();
        const size_t length=size_t(p[at])*256+p[at+1];
        if (length<2 || length>size-at) invalid();
        output.push_back({marker,p+at+2,length-2});
        if (marker==0xda) return output;
        at+=length;
    }
    invalid();
}
bool starts(const Segment& s,const char* prefix,size_t length) {
    return s.size>=length && std::memcmp(s.data,prefix,length)==0;
}
struct Entry { uint16_t type; uint32_t count; std::vector<uint8_t> bytes; };
using Directory=std::map<uint16_t,Entry>;
struct TIFF {
    const uint8_t* data; size_t size; bool little=false;
    Directory primary,exif,gps;
    std::set<uint32_t> visited;
    TIFF(const void* bytes,size_t length):data(static_cast<const uint8_t*>(bytes)),size(length) {
        if (!size) return;
        if (!data || size<8 || size>1024*1024) invalid();
        little=data[0]=='I' && data[1]=='I';
        if ((!little && !(data[0]=='M' && data[1]=='M')) || u16(2)!=42) invalid();
        directory(u32(4),&primary,0);
    }
    void range(size_t offset,size_t length) const { if (offset>size || length>size-offset) invalid(); }
    uint16_t u16(size_t offset) const { range(offset,2); return little ? data[offset]|uint16_t(data[offset+1])<<8 : uint16_t(data[offset])<<8|data[offset+1]; }
    uint32_t u32(size_t offset) const {
        range(offset,4); uint32_t value=0;
        for (int i=0;i<4;++i) value|=uint32_t(data[offset+i])<<(8*(little ? i : 3-i));
        return value;
    }
    void directory(uint32_t offset,Directory* save,unsigned depth) {
        if (!offset) return;
        if (depth>8 || visited.size()>=32 || !visited.insert(offset).second) invalid();
        const uint16_t count=u16(offset);
        if (count>4096) invalid();
        range(offset,size_t(count)*12+6);
        std::set<uint16_t> tags;
        for (uint32_t i=0;i<count;++i) {
            const size_t at=offset+2+size_t(i)*12;
            const uint16_t tag=u16(at),type=u16(at+2); const uint32_t n=u32(at+4);
            static constexpr uint8_t widths[]={0,1,1,2,4,8,1,1,2,4,8,4,8,4};
            if (!type || type>=sizeof(widths) || !tags.insert(tag).second) invalid();
            const uint64_t length=uint64_t(n)*widths[type];
            if (length>size) invalid();
            const size_t value=length<=4 ? at+8 : u32(at+8);
            range(value,size_t(length));
            if (tag==0x8769 || tag==0x8825 || tag==0xa005 || tag==0x014a) {
                if ((type!=4 && type!=13) || !n || n>32) invalid();
                for (uint32_t child=0;child<n;++child) {
                    auto* target=(tag==0x8769 && save==&primary) ? &exif :
                        (tag==0x8825 && save==&primary) ? &gps : nullptr;
                    directory(u32(value+size_t(child)*4),target,depth+1);
                }
            }
            Entry entry{type,n,{data+value,data+value+size_t(length)}};
            if (!little && widths[type]>1) {
                const size_t unit=(type==5 || type==10) ? 4 : widths[type];
                for (size_t byte=0;byte<entry.bytes.size();byte+=unit)
                    std::reverse(entry.bytes.begin()+byte,entry.bytes.begin()+byte+unit);
            }
            if (save) save->emplace(tag,std::move(entry));
        }
        directory(u32(offset+2+size_t(count)*12),nullptr,depth+1);
    }
};
uint32_t scalar(const Entry& e) {
    if (e.count!=1 || (e.type!=3 && e.type!=4)) invalid();
    uint32_t value=0; for (size_t i=0;i<e.bytes.size();++i) value|=uint32_t(e.bytes[i])<<(8*i);
    return value;
}
Entry number(uint32_t value,uint16_t type=4) {
    Entry result{type,1,{}};
    for (unsigned i=0;i<(type==3 ? 2u : 4u);++i) result.bytes.push_back(uint8_t(value>>(i*8)));
    return result;
}
void copyTags(const Directory& source,Directory& output,const std::set<uint16_t>& allowed) {
    for (const auto& [tag,entry]:source) if (allowed.count(tag)) {
        if (entry.bytes.size()>16384 || (entry.type==2 && (entry.bytes.empty() || entry.bytes.back()!=0))) invalid();
        output.emplace(tag,entry);
    }
}
void put16(std::vector<uint8_t>& output,size_t at,uint16_t value) { output[at]=uint8_t(value); output[at+1]=uint8_t(value>>8); }
void put32(std::vector<uint8_t>& output,size_t at,uint32_t value) { for (int i=0;i<4;++i) output[at+i]=uint8_t(value>>(8*i)); }
void emit(std::vector<uint8_t>& output,size_t offset,const Directory& entries) {
    put16(output,offset,uint16_t(entries.size())); size_t at=offset+2;
    for (const auto& [tag,entry]:entries) {
        put16(output,at,tag); put16(output,at+2,entry.type); put32(output,at+4,entry.count);
        if (entry.bytes.size()<=4) std::copy(entry.bytes.begin(),entry.bytes.end(),output.begin()+at+8);
        else {
            if (output.size()&1) output.push_back(0);
            put32(output,at+8,uint32_t(output.size()));
            output.insert(output.end(),entry.bytes.begin(),entry.bytes.end());
        }
        at+=12;
    }
}
}

std::vector<uint8_t> jpegExif(const void* jpeg,size_t size) {
    std::vector<uint8_t> result;
    for (const auto& s:segments(jpeg,size)) if (s.marker==0xe1 && starts(s,"Exif\0\0",6)) {
        if (!result.empty()) invalid();
        result.assign(s.data+6,s.data+s.size); if (result.empty()) invalid();
        TIFF parsed(result.data(),result.size());
    }
    return result;
}
uint32_t exifOrientation(const void* bytes,size_t size) {
    TIFF parsed(bytes,size); const auto found=parsed.primary.find(0x0112);
    const uint32_t value=found==parsed.primary.end() ? 1 : scalar(found->second);
    if (value<1 || value>8) invalid(); return value;
}
float appleHeadroom(const void* bytes,size_t size) {
    TIFF parsed(bytes,size); const auto found=parsed.exif.find(0x927c);
    if (found==parsed.exif.end()) invalid();
    const auto& note=found->second.bytes;
    if (note.size()<16 || std::memcmp(note.data(),"Apple iOS\0",10) || note[12]!='M' || note[13]!='M') invalid();
    auto u16=[&](size_t at) { if (at>note.size() || note.size()-at<2) invalid(); return uint16_t(note[at])<<8|note[at+1]; };
    auto u32=[&](size_t at) { if (at>note.size() || note.size()-at<4) invalid(); return uint32_t(note[at])<<24|uint32_t(note[at+1])<<16|uint32_t(note[at+2])<<8|note[at+3]; };
    const auto count=u16(14); if (count>4096 || size_t(count)*12>note.size()-16) invalid();
    double maker33=0,maker48=0; bool have33=false,have48=false;
    for (unsigned i=0;i<count;++i) {
        const size_t at=16+size_t(i)*12; const unsigned tag=u16(at);
        if (tag!=33 && tag!=48) continue;
        if (u16(at+2)!=10 || u32(at+4)!=1) invalid();
        const size_t offset=u32(at+8); const int32_t numerator=int32_t(u32(offset)),denominator=int32_t(u32(offset+4));
        if (!denominator) invalid(); const double value=double(numerator)/denominator;
        if (!std::isfinite(value)) invalid();
        if (tag==33) { if (have33) invalid(); maker33=value; have33=true; }
        else { if (have48) invalid(); maker48=value; have48=true; }
    }
    if (!have33 || !have48) invalid();
    const double stops=maker33<1 ? (maker48<=.01 ? -20*maker48+1.8 : -.101*maker48+1.601) :
        (maker48<=.01 ? -70*maker48+3 : -.303*maker48+2.303);
    const double headroom=std::exp2(std::max(stops,0.0));
    if (!std::isfinite(headroom) || headroom>std::numeric_limits<float>::max()) invalid();
    return float(headroom);
}
AppleGainMapMetadata appleGainMapMetadata(const void* bytes,size_t size) {
    using namespace photos_editing_formats::image_io;
    if (!bytes || !size || size>1024*1024) invalid();
    struct Handler : XmlHandler {
        struct Frame { std::string name,attribute,text; std::map<std::string,std::string> namespaces,attributes; bool children=false; };
        std::vector<Frame> frames; std::string version,headroom,auxiliary; std::map<std::string,std::string> tone; bool hasVersion=false,hasHeadroom=false;
        static std::string token(const XmlTokenContext& context) { std::string value; context.BuildTokenValue(&value); return value; }
        DataMatchResult StartElement(const XmlTokenContext& c) override {
            if (frames.size()>=64) invalid();
            Frame next; next.name=token(c);
            if (!frames.empty()) { next.namespaces=frames.back().namespaces; frames.back().children=true; }
            frames.push_back(std::move(next)); return c.GetResult();
        }
        DataMatchResult AttributeName(const XmlTokenContext& c) override { if (frames.empty()) invalid(); frames.back().attribute=token(c); return c.GetResult(); }
        DataMatchResult AttributeValue(const XmlTokenContext& c) override {
            if (frames.empty()) invalid(); auto& frame=frames.back(); auto value=token(c);
            if (value.size()<2) invalid(); value=value.substr(1,value.size()-2);
            if (!frame.attributes.emplace(frame.attribute,value).second || frame.attributes.size()>64) invalid();
            if (frame.attribute=="xmlns") frame.namespaces[""]=value;
            else if (frame.attribute.rfind("xmlns:",0)==0) frame.namespaces[frame.attribute.substr(6)]=value;
            return c.GetResult();
        }
        DataMatchResult ElementContent(const XmlTokenContext& c) override {
            if (!frames.empty()) frames.back().text+=token(c); return c.GetResult();
        }
        void property(const Frame& frame,const std::string& name,const std::string& text,bool attribute) {
            const auto colon=name.find(':');
            if (colon==std::string::npos && attribute) return;
            const auto prefix=colon==std::string::npos ? std::string{} : name.substr(0,colon);
            const auto local=colon==std::string::npos ? name : name.substr(colon+1);
            const auto ns=frame.namespaces.find(prefix);
            if (ns==frame.namespaces.end()) return;
            const bool apple=ns->second=="http://ns.apple.com/HDRGainMap/1.0/";
            const bool adobe=ns->second=="http://ns.adobe.com/hdr-gain-map/1.0/";
            const bool auxiliaryType=ns->second=="http://ns.apple.com/pixeldatainfo/1.0/" && local=="AuxiliaryImageType";
            if (!apple && !adobe && !auxiliaryType) return;
            if (!attribute && frame.children) return;
            if (apple && local=="HDRGainMapVersion") { if (hasVersion) invalid(); version=text; hasVersion=true; }
            else if (apple && local=="HDRGainMapHeadroom") { if (hasHeadroom) invalid(); headroom=text; hasHeadroom=true; }
            else if (adobe) { if (!tone.emplace(local,text).second) invalid(); }
            else if (auxiliaryType) { if (!auxiliary.empty()) invalid(); auxiliary=text; }
        }
        DataMatchResult FinishElement(const XmlTokenContext& c) override {
            if (frames.empty()) invalid(); const auto& frame=frames.back(); const auto end=token(c);
            if (!end.empty() && end!=frame.name) invalid();
            property(frame,frame.name,frame.text,false);
            for (const auto& [name,value]:frame.attributes) property(frame,name,value,true);
            frames.pop_back(); return c.GetResult();
        }
    } handler;
    std::string xml(static_cast<const char*>(bytes),size);
    // XMP packet wrapper 是 processing instruction，上游 XML reader 只接收根元素。
    size_t start=0,end=xml.size();
    while (start<end && std::isspace(static_cast<unsigned char>(xml[start]))) ++start;
    while (xml.compare(start,2,"<?")==0) {
        const auto close=xml.find("?>",start+2); if (close==std::string::npos) invalid(); start=close+2;
        while (start<end && std::isspace(static_cast<unsigned char>(xml[start]))) ++start;
    }
    while (end>start && std::isspace(static_cast<unsigned char>(xml[end-1]))) --end;
    if (end>=2 && xml.compare(end-2,2,"?>")==0) { const auto open=xml.rfind("<?",end-2); if (open==std::string::npos) invalid(); end=open; }
    MessageHandler messages; XmlReader reader(&handler,&messages);
    reader.StartParse(std::make_unique<XmlElementRule>()); reader.Parse(xml.substr(start,end-start)); reader.FinishParse();
    if (reader.HasErrors() || !handler.frames.empty()) invalid();
    auto numeric=[](const std::string& text) {
        std::istringstream input(text); input.imbue(std::locale::classic()); double number;
        if (!(input>>number) || !(input>>std::ws).eof() || !std::isfinite(number)) invalid(); return number;
    };
    AppleGainMapMetadata result;
    auto ratio=[&](double stops) {
        const double value=std::exp2(stops);
        if (!std::isfinite(value) || value<=0 || value>std::numeric_limits<float>::max()) invalid();
        return float(value);
    };
    if (handler.hasVersion) {
        if (numeric(handler.version)!=65536)
            throw Error(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_UNSUPPORTED_VERSION,SONY2FUJI_HDR_FIELD_SOURCE,"Unsupported Apple gain-map version");
        if (handler.hasHeadroom) result.headroom=ratio(numeric(handler.headroom));
        if (result.headroom && result.headroom<1) invalid();
        return result;
    }
    // 旧式 Apple JPEG 使用 Adobe 元素，但仍须有真实的 Apple 辅助类型声明。
    if (handler.auxiliary!="urn:com:apple:photo:2020:aux:hdrgainmap") invalid();
    auto value=[&](const char* name) {const auto at=handler.tone.find(name);if(at==handler.tone.end())invalid();return numeric(at->second);};
    if (value("Version")!=1)
        throw Error(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_UNSUPPORTED_VERSION,SONY2FUJI_HDR_FIELD_SOURCE,"Unsupported Apple tone-map version");
    if (value("BaseRenditionIsHDR")!=0 || value("BaseHeadroom")!=0) invalid();
    result.logarithmic=true;
    result.headroom=ratio(value("AlternateHeadroom"));result.minBoost=ratio(value("GainMapMin"));result.maxBoost=ratio(value("GainMapMax"));
    result.gamma=float(value("Gamma"));result.offsetSDR=float(value("OffsetSDR"));result.offsetHDR=float(value("OffsetHDR"));
    if (result.headroom<1 || result.minBoost>result.maxBoost || !std::isfinite(result.gamma) || result.gamma<=0 ||
        !std::isfinite(result.offsetSDR) || !std::isfinite(result.offsetHDR) || result.offsetSDR<0 || result.offsetHDR<0) invalid();
    return result;
}
float appleXMPHeadroom(const void* bytes,size_t size) {
    const auto description=appleGainMapMetadata(bytes,size);
    if (description.logarithmic)
        throw Error(SONY2FUJI_STATUS_UNSUPPORTED,SONY2FUJI_HDR_REASON_UNSUPPORTED_PROTOCOL,SONY2FUJI_HDR_FIELD_SOURCE,"Apple HEIF tone-map variant is unsupported");
    return description.headroom;
}

std::vector<uint8_t> sanitizedExif(const void* bytes,size_t size,uint32_t width,uint32_t height) {
    TIFF parsed(bytes,size); Directory primary,exif,gps;
    copyTags(parsed.primary,primary,{0x010e,0x010f,0x0110,0x0132,0x013b,0x8298});
    copyTags(parsed.exif,exif,{0x829a,0x829d,0x8822,0x8827,0x8830,0x8831,0x8832,0x9000,0x9003,0x9004,
        0x9010,0x9011,0x9012,0x9201,0x9202,0x9203,0x9204,0x9205,0x9206,0x9207,0x9208,0x9209,0x920a,
        0x9286,0x9290,0x9291,0x9292,0xa20b,0xa215,0xa217,0xa402,0xa403,0xa404,0xa405,0xa406,
        0xa420,0xa430,0xa431,0xa432,0xa433,0xa434,0xa435});
    std::set<uint16_t> gpsTags; for (uint16_t tag=0;tag<=31;++tag) gpsTags.insert(tag);
    copyTags(parsed.gps,gps,gpsTags);
    primary[0x0100]=number(width); primary[0x0101]=number(height); primary[0x0112]=number(1,3);
    primary[0x0131]={2,7,{'R','a','w','L','a','b',0}};
    exif[0xa002]=number(width); exif[0xa003]=number(height); exif[0xa001]=number(65535,3);
    primary[0x8769]=number(0); if (!gps.empty()) primary[0x8825]=number(0);
    const size_t exifOffset=8+2+primary.size()*12+4, gpsOffset=exifOffset+2+exif.size()*12+4;
    primary[0x8769]=number(uint32_t(exifOffset));
    if (!gps.empty()) primary[0x8825]=number(uint32_t(gpsOffset));
    std::vector<uint8_t> output(gpsOffset+(gps.empty() ? 0 : 2+gps.size()*12+4),0);
    output[0]=output[1]='I'; put16(output,2,42); put32(output,4,8);
    emit(output,8,primary); emit(output,exifOffset,exif);
    if (!gps.empty()) emit(output,gpsOffset,gps);
    if (output.size()>65527) invalid(); return output;
}
std::vector<uint8_t> withJPEGExif(const void* jpeg,size_t size,const void* tiff,size_t tiffSize) {
    if (!tiff || !tiffSize || tiffSize>65527) invalid();
    TIFF checked(tiff,tiffSize);
    if (!jpegExif(jpeg,size).empty()) invalid();
    const auto* p=static_cast<const uint8_t*>(jpeg); const auto* t=static_cast<const uint8_t*>(tiff);
    const size_t length=tiffSize+8;
    std::vector<uint8_t> result{255,0xd8,255,0xe1,uint8_t(length>>8),uint8_t(length),'E','x','i','f',0,0};
    result.insert(result.end(),t,t+tiffSize); result.insert(result.end(),p+2,p+size); return result;
}
uint32_t jpegColorDescription(const void* jpeg,size_t size,bool allowExifSRGB) {
    std::map<unsigned,std::vector<uint8_t>> parts; unsigned total=0;
    for (const auto& s:segments(jpeg,size)) if (s.marker==0xe2 && starts(s,"ICC_PROFILE\0",12)) {
        if (s.size<14 || !s.data[12] || !s.data[13] || s.data[12]>s.data[13] ||
            (total && total!=s.data[13]) || parts.count(s.data[12])) invalid();
        total=s.data[13]; parts.emplace(s.data[12],std::vector<uint8_t>(s.data+14,s.data+s.size));
    }
    if (!total) {
        if (!allowExifSRGB) return SONY2FUJI_HDR_COLOR_UNKNOWN;
        const auto bytes=jpegExif(jpeg,size);TIFF parsed(bytes.data(),bytes.size());
        const auto color=parsed.exif.find(0xa001);
        if (color!=parsed.exif.end() && color->second.type==3 && color->second.count==1 &&
            color->second.bytes==std::vector<uint8_t>{1,0}) return SONY2FUJI_HDR_COLOR_SRGB;
        return SONY2FUJI_HDR_COLOR_UNKNOWN;
    }
    if (parts.size()!=total) invalid();
    std::vector<uint8_t> icc;
    for (const auto& part:parts) { icc.insert(icc.end(),part.second.begin(),part.second.end()); if (icc.size()>1024*1024) invalid(); }
    return iccColorDescription(icc.data(),icc.size(),true);
}
uint32_t iccColorDescription(const void* icc,size_t size,bool requireSRGBTransfer) {
    if (!icc || size<132 || size>1024*1024) invalid();
    auto profile=cmsOpenProfileFromMem(icc,uint32_t(size));
    if (!profile) invalid();
    struct Close { cmsHPROFILE value; ~Close() { cmsCloseProfile(value); } } close{profile};
    if (cmsGetColorSpace(profile)!=cmsSigRgbData) invalid();
    if (requireSRGBTransfer) {
        // JPEG 的 Ultra HDR 路径固定使用 sRGB inverse transfer，不能只比较原色。
        for (auto tag : {cmsSigRedTRCTag,cmsSigGreenTRCTag,cmsSigBlueTRCTag}) {
            const auto* curve=static_cast<const cmsToneCurve*>(cmsReadTag(profile,tag));
            if (!curve) return SONY2FUJI_HDR_COLOR_UNKNOWN;
            for (unsigned i=0;i<=1024;++i) {
                const float x=float(i)/1024;
                const float expected=x<=.04045f ? x/12.92f : std::pow((x+.055f)/1.055f,2.4f);
                const float actual=cmsEvalToneCurveFloat(curve,x);
                if (!std::isfinite(actual) || std::abs(actual-expected)>.0025f)
                    return SONY2FUJI_HDR_COLOR_UNKNOWN;
            }
        }
    }
    const auto* r=static_cast<const cmsCIEXYZ*>(cmsReadTag(profile,cmsSigRedColorantTag));
    const auto* g=static_cast<const cmsCIEXYZ*>(cmsReadTag(profile,cmsSigGreenColorantTag));
    const auto* b=static_cast<const cmsCIEXYZ*>(cmsReadTag(profile,cmsSigBlueColorantTag));
    if (!r || !g || !b) return SONY2FUJI_HDR_COLOR_UNKNOWN;
    const std::array<double,9> values={r->X,r->Y,r->Z,g->X,g->Y,g->Z,b->X,b->Y,b->Z};
    const std::array<std::array<double,9>,3> known={{{.436066,.222488,.013916,.385147,.716873,.097076,.143066,.060608,.714096},
        {.515102,.241182,-.001049,.291965,.692237,.041882,.157153,.066582,.784378},
        {.673459,.279033,-.001931,.165661,.675338,.029979,.125100,.045629,.797162}}};
    for (size_t gamut=0;gamut<known.size();++gamut) {
        bool same=true; for (size_t i=0;i<9;++i) same&=std::isfinite(values[i]) && std::abs(values[i]-known[gamut][i])<.003;
        if (same) return uint32_t(gamut)+SONY2FUJI_HDR_COLOR_SRGB;
    }
    return SONY2FUJI_HDR_COLOR_UNKNOWN;
}
} // namespace sony2fuji::hdr
