#include "sony2fuji/ffi/sony2fuji_c.h"
#include "core/sony_ptpip.h"

#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

int g_failures = 0;

void check(bool cond, const char* msg) {
    if (!cond) {
        std::fprintf(stderr, "FAIL: %s\n", msg);
        ++g_failures;
    }
}

void appendU16(std::vector<uint8_t>& out, uint16_t v) {
    out.push_back(static_cast<uint8_t>(v & 0xffu));
    out.push_back(static_cast<uint8_t>((v >> 8) & 0xffu));
}

void appendU32(std::vector<uint8_t>& out, uint32_t v) {
    out.push_back(static_cast<uint8_t>(v & 0xffu));
    out.push_back(static_cast<uint8_t>((v >> 8) & 0xffu));
    out.push_back(static_cast<uint8_t>((v >> 16) & 0xffu));
    out.push_back(static_cast<uint8_t>((v >> 24) & 0xffu));
}

void appendU64(std::vector<uint8_t>& out, uint64_t v) {
    appendU32(out, static_cast<uint32_t>(v & 0xffffffffu));
    appendU32(out, static_cast<uint32_t>((v >> 32) & 0xffffffffu));
}

void appendPtpString(std::vector<uint8_t>& out, const std::string& ascii) {
    out.push_back(static_cast<uint8_t>(ascii.size() + 1u));
    for (char ch : ascii) {
        out.push_back(static_cast<uint8_t>(ch));
        out.push_back(0u);
    }
    out.push_back(0u);
    out.push_back(0u);
}

void testPtpipFraming() {
    uint8_t guid[16]{};
    for (int i = 0; i < 16; ++i) guid[i] = static_cast<uint8_t>(i + 1);

    size_t need = 0;
    check(sony2fuji_sony_ptpip_build_init_cmd(guid, "RawLab", 0x10000u, nullptr, 0, &need) == SONY2FUJI_STATUS_OK,
          "init_cmd size query");
    check(need == 8u + 16u + 14u + 4u, "init_cmd exact byte length");
    std::vector<uint8_t> buf(need);
    size_t actual = 0;
    check(sony2fuji_sony_ptpip_build_init_cmd(guid, "RawLab", 0x10000u, buf.data(), buf.size(), &actual) == SONY2FUJI_STATUS_OK &&
              actual == need,
          "init_cmd builds packet");
    sony2fuji_sony_ptpip_header hdr{};
    check(sony2fuji_sony_ptpip_parse_header(buf.data(), 8u, 4096u, &hdr) == SONY2FUJI_STATUS_OK &&
              hdr.packet_type == 1u && hdr.payload_size == need - 8u,
          "parse_header reads init_cmd");
    check(sony2fuji_sony_ptpip_parse_header(buf.data(), 8u, 4u, &hdr) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "parse_header rejects oversized payload");
    uint8_t bad_hdr[8]{4, 0, 0, 0, 1, 0, 0, 0};
    check(sony2fuji_sony_ptpip_parse_header(bad_hdr, 8u, 4096u, &hdr) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "parse_header rejects length < 8");

    uint8_t ack[24]{0x44, 0x33, 0x22, 0x11};
    uint32_t conn = 0;
    check(sony2fuji_sony_ptpip_parse_init_cmd_ack(ack, sizeof(ack), &conn) == SONY2FUJI_STATUS_OK &&
              conn == 0x11223344u,
          "parse_init_cmd_ack");
    check(sony2fuji_sony_ptpip_parse_init_cmd_ack(ack, 23u, &conn) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "parse_init_cmd_ack rejects short payload");

    uint8_t evt_buf[12]{};
    size_t evt_len = 0;
    check(sony2fuji_sony_ptpip_build_init_evt(conn, evt_buf, sizeof(evt_buf), &evt_len) == SONY2FUJI_STATUS_OK &&
              evt_len == 12u,
          "build_init_evt");

    uint32_t params[2]{0x10u, 0x20u};
    uint8_t op_buf[32]{};
    size_t op_len = 0;
    check(sony2fuji_sony_ptpip_build_op_req(1u, 0x923cu, 7u, params, 2u, op_buf, sizeof(op_buf), &op_len) == SONY2FUJI_STATUS_OK &&
              op_len == 8u + 10u + 8u,
          "build_op_req");
    check(sony2fuji_sony_ptpip_build_op_req(1u, 0x923cu, 7u, params, 6u, op_buf, sizeof(op_buf), &op_len) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "build_op_req rejects > 5 params");

    uint8_t start_buf[20]{};
    size_t start_len = 0;
    check(sony2fuji_sony_ptpip_build_start_data(7u, 12345ULL, start_buf, sizeof(start_buf), &start_len) == SONY2FUJI_STATUS_OK &&
              start_len == 20u,
          "build_start_data");
    sony2fuji_sony_ptpip_start_data start_parsed{};
    check(sony2fuji_sony_ptpip_parse_start_data(start_buf + 8, 12u, &start_parsed) == SONY2FUJI_STATUS_OK &&
              start_parsed.transaction_id == 7u && start_parsed.total_bytes == 12345ULL,
          "parse_start_data");

    uint8_t payload[3]{1, 2, 3};
    uint8_t end_buf[32]{};
    size_t end_len = 0;
    check(sony2fuji_sony_ptpip_build_end_data(7u, payload, sizeof(payload), end_buf, sizeof(end_buf), &end_len) == SONY2FUJI_STATUS_OK &&
              end_len == 15u,
          "build_end_data");

    uint8_t probe_buf[8]{};
    size_t probe_len = 0;
    check(sony2fuji_sony_ptpip_build_probe_resp(probe_buf, sizeof(probe_buf), &probe_len) == SONY2FUJI_STATUS_OK &&
              probe_len == 8u,
          "build_probe_resp");

    std::vector<uint8_t> resp_bytes{0x01, 0x20, 7, 0, 0, 0, 0xaa, 0, 0, 0};
    sony2fuji_sony_ptpip_response resp{};
    check(sony2fuji_sony_ptpip_parse_response(resp_bytes.data(), resp_bytes.size(), &resp) == SONY2FUJI_STATUS_OK &&
              resp.response_code == 0x2001u && resp.transaction_id == 7u && resp.param_count == 1u &&
              resp.params[0] == 0xaau,
          "parse_response");
    check(sony2fuji_sony_ptpip_parse_response(resp_bytes.data(), 7u, &resp) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "parse_response rejects unaligned length");

    std::vector<uint8_t> evt_bytes{0x02, 0xc2, 9, 0, 0, 0, 1, 0, 0, 0, 2, 0, 0, 0};
    sony2fuji_sony_ptpip_event evt{};
    check(sony2fuji_sony_ptpip_parse_event(evt_bytes.data(), evt_bytes.size(), &evt) == SONY2FUJI_STATUS_OK &&
              evt.event_code == 0xc202u && evt.transaction_id == 9u && evt.param_count == 2u,
          "parse_event");
    check(sony2fuji_sony_ptpip_parse_event(evt_bytes.data(), 22u, &evt) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "parse_event rejects > 18 bytes");
}

void testCredentialsAndHeaders() {
    std::vector<uint8_t> ssid{11, 0, 0, 'D', 'I', 'R', 'E', 'C', 'T', '-', 'X', 0};
    char out[64]{};
    size_t len = 0;
    check(sony2fuji_sony_parse_wifi_credential(ssid.data(), ssid.size(), 0, out, sizeof(out), &len) == SONY2FUJI_STATUS_OK &&
              len == 8u && std::string(out) == "DIRECT-X",
          "parse_wifi_credential SSID strips trailing NUL");
    std::vector<uint8_t> short_pw{9, 0, 0, '1', '2', '3', '4', '5', '6', '7'};
    check(sony2fuji_sony_parse_wifi_credential(short_pw.data(), short_pw.size(), 1, out, sizeof(out), &len) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "parse_wifi_credential rejects < 8 byte password");
    std::vector<uint8_t> non_ascii{4, 0, 0, 'A', 0x7fu};
    check(sony2fuji_sony_parse_wifi_credential(non_ascii.data(), non_ascii.size(), 0, out, sizeof(out), &len) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "parse_wifi_credential rejects non-printable ASCII");

    check(sony2fuji_sony_is_valid_photo_filename("DSC00001.ARW") == 1, "valid filename");
    check(sony2fuji_sony_is_valid_photo_filename("..") == 0, "reject .. filename");
    check(sony2fuji_sony_is_valid_photo_filename("a/b.jpg") == 0, "reject slash in filename");
    check(sony2fuji_sony_is_photo_filename("a.JpEg") == 1 && sony2fuji_sony_is_photo_filename("a.mp4") == 0,
          "photo extension check");

    const uint8_t tiff_le[4]{0x49, 0x49, 0x2a, 0x00};
    const uint8_t tiff_be[4]{0x4d, 0x4d, 0x00, 0x2a};
    const uint8_t jpeg[3]{0xff, 0xd8, 0xff};
    check(sony2fuji_sony_validate_photo_header("DSC.ARW", tiff_le, 4) == 1 &&
              sony2fuji_sony_validate_photo_header("DSC.arw", tiff_be, 4) == 1 &&
              sony2fuji_sony_validate_photo_header("DSC.ARW", jpeg, 3) == 0 &&
              sony2fuji_sony_validate_photo_header("DSC.JPG", jpeg, 3) == 1 &&
              sony2fuji_sony_validate_photo_header("DSC.JPG", tiff_le, 4) == 0,
          "validate_photo_header matches TIFF/JPEG");
}

void testDeviceInfoAndRemoteDescriptor() {
    auto buildDevice = [&](uint32_t vendor, const std::string& maker) {
        std::vector<uint8_t> d;
        appendU16(d, 100);
        appendU32(d, vendor);
        appendU16(d, 100);
        appendPtpString(d, "Sony");
        appendU16(d, 0);
        appendU32(d, 2);
        appendU16(d, 0x1001);
        appendU16(d, 0x923c);
        for (int i = 0; i < 4; ++i) appendU32(d, 0);
        appendPtpString(d, maker);
        appendPtpString(d, "ILCE-7M5");
        appendPtpString(d, "1.00");
        appendPtpString(d, "0001");
        return d;
    };

    const auto ok_dev = buildDevice(17u, "Sony Corporation");
    sony2fuji_sony_device_info* info = nullptr;
    check(sony2fuji_sony_parse_device_info(ok_dev.data(), ok_dev.size(), &info) == SONY2FUJI_STATUS_OK && info != nullptr,
          "parse_device_info succeeds");
    check(std::string(sony2fuji_sony_device_info_model(info)) == "ILCE-7M5" &&
              std::string(sony2fuji_sony_device_info_firmware(info)) == "1.00" &&
              std::string(sony2fuji_sony_device_info_serial(info)) == "0001",
          "device_info strings");
    uint16_t ops[4]{};
    uint32_t op_count = 0;
    check(sony2fuji_sony_device_info_operations(info, ops, 4, &op_count) == SONY2FUJI_STATUS_OK &&
              op_count == 2u && ops[0] == 0x1001u && ops[1] == 0x923cu,
          "device_info operations");
    sony2fuji_sony_device_info_free(info);

    const auto bad_vendor = buildDevice(6u, "Sony");
    check(sony2fuji_sony_parse_device_info(bad_vendor.data(), bad_vendor.size(), &info) == SONY2FUJI_STATUS_UNSUPPORTED &&
              info == nullptr,
          "non-Sony vendor rejected as UNSUPPORTED");

    // 0x9202 versions: 0xc8 exact, 0xc8 trailing rejected, 0x12c trailing accepted, 0x190 accepted, 0x64 rejected
    auto buildDesc = [](uint16_t version, bool trailing) {
        std::vector<uint8_t> d;
        appendU16(d, version);
        appendU32(d, 1);
        appendU16(d, 0x500au);
        appendU32(d, 1);
        appendU16(d, 0xd2e4u);
        if (trailing) {
            appendU16(d, 0x9999u);
            appendU32(d, 1u);
        }
        return d;
    };

    uint16_t ver = 0;
    int32_t tables = 0;
    sony2fuji_sony_remote_descriptor* desc = nullptr;
    const auto d_c8 = buildDesc(0xc8u, false);
    check(sony2fuji_sony_parse_remote_descriptor(d_c8.data(), d_c8.size(), &ver, &tables, &desc) == SONY2FUJI_STATUS_OK &&
              ver == 0xc8u && tables == 1,
          "0x9202 v0xc8 exact -> 1 enum table");
    uint16_t props[4]{};
    uint32_t prop_count = 0;
    check(sony2fuji_sony_remote_descriptor_properties(desc, props, 4, &prop_count) == SONY2FUJI_STATUS_OK &&
              prop_count == 1 && props[0] == 0x500au,
          "0x9202 properties");
    sony2fuji_sony_remote_descriptor_free(desc);

    const auto d_c8_trail = buildDesc(0xc8u, true);
    check(sony2fuji_sony_parse_remote_descriptor(d_c8_trail.data(), d_c8_trail.size(), &ver, &tables, &desc) == SONY2FUJI_STATUS_UNSUPPORTED,
          "0x9202 v0xc8 with trailing bytes rejected");

    const auto d_190_trail = buildDesc(0x190u, true);
    check(sony2fuji_sony_parse_remote_descriptor(d_190_trail.data(), d_190_trail.size(), &ver, &tables, &desc) == SONY2FUJI_STATUS_OK &&
              ver == 0x190u && tables == 2,
          "0x9202 v0x190 forward-compatible -> 2 enum tables");
    sony2fuji_sony_remote_descriptor_free(desc);

    const auto d_64 = buildDesc(0x64u, false);
    check(sony2fuji_sony_parse_remote_descriptor(d_64.data(), d_64.size(), &ver, &tables, &desc) == SONY2FUJI_STATUS_UNSUPPORTED,
          "0x9202 v0x64 rejected");
}

void testPropertiesAndFocusPolicy() {
    std::vector<uint8_t> p;
    appendU64(p, 5u);
    // 1. 0xd21e u32 enabled=2 writable=1 form=2 choices=[100,200,400] (table1=[50,100,200,400])
    appendU16(p, 0xd21eu);
    appendU16(p, 6u);
    p.push_back(1u);
    p.push_back(2u);
    appendU32(p, 100u);
    appendU32(p, 100u);
    p.push_back(2u);
    appendU16(p, 3u);
    appendU32(p, 100u);
    appendU32(p, 200u);
    appendU32(p, 400u);
    appendU16(p, 4u);
    appendU32(p, 50u);
    appendU32(p, 100u);
    appendU32(p, 200u);
    appendU32(p, 400u);
    // 2. 0x5010 i16 enabled=1 writable=1 form=1 [-2000, 2000, step=1000]
    appendU16(p, 0x5010u);
    appendU16(p, 3u);
    p.push_back(1u);
    p.push_back(1u);
    appendU16(p, 0u);
    appendU16(p, 0u);
    p.push_back(1u);
    appendU16(p, static_cast<uint16_t>(int16_t(-2000)));
    appendU16(p, static_cast<uint16_t>(int16_t(2000)));
    appendU16(p, static_cast<uint16_t>(int16_t(1000)));
    // 3. 0xd278 text (0xffff)
    appendU16(p, 0xd278u);
    appendU16(p, 0xffffu);
    p.push_back(0u);
    p.push_back(1u);
    appendPtpString(p, "http://localhost:8080/liveviewstream");
    appendPtpString(p, "http://localhost:8080/liveviewstream");
    p.push_back(0u);
    // 4. 0xd284 u8=1
    appendU16(p, 0xd284u);
    appendU16(p, 2u);
    p.push_back(0u);
    p.push_back(1u);
    p.push_back(1u);
    p.push_back(1u);
    p.push_back(0u);
    // 5. 0xd213 u8=6 (focus locked)
    appendU16(p, 0xd213u);
    appendU16(p, 2u);
    p.push_back(0u);
    p.push_back(1u);
    p.push_back(6u);
    p.push_back(6u);
    p.push_back(0u);

    sony2fuji_sony_property_table* table = nullptr;
    check(sony2fuji_sony_parse_properties(p.data(), p.size(), 2, &table) == SONY2FUJI_STATUS_OK &&
              sony2fuji_sony_property_table_count(table) == 5u,
          "parse_properties succeeds");

    sony2fuji_sony_property_info iso{};
    check(sony2fuji_sony_property_table_find(table, 0xd21eu, &iso) == SONY2FUJI_STATUS_OK &&
              iso.choice_count == 3u,
          "find 0xd21e");
    int64_t choices[8]{};
    uint32_t ccount = 0;
    check(sony2fuji_sony_property_table_choices_at(table, 0u, choices, 8, &ccount) == SONY2FUJI_STATUS_OK &&
              ccount == 3u,
          "choices_at 0xd21e");
    // Android mode: only_settable=0 returns [100,200,400] even though enabled=2
    int64_t opts[8]{};
    uint32_t ocount = 0;
    check(sony2fuji_sony_property_options(&iso, choices, ccount, 0, 0, 4096, opts, 8, &ocount) == SONY2FUJI_STATUS_OK &&
              ocount == 3u && opts[0] == 100 && opts[2] == 400,
          "Android options() ignores enabled/writable for form=2");
    // iOS mode: only_settable=1 returns empty when enabled!=1
    check(sony2fuji_sony_property_options(&iso, choices, ccount, 1, 1, 513, opts, 8, &ocount) == SONY2FUJI_STATUS_OK &&
              ocount == 0u,
          "iOS selectableValues filters disabled property");

    sony2fuji_sony_property_info ev{};
    check(sony2fuji_sony_property_table_find(table, 0x5010u, &ev) == SONY2FUJI_STATUS_OK &&
              sony2fuji_sony_property_accepts(&ev, nullptr, 0, -1000) == 1 &&
              sony2fuji_sony_property_accepts(&ev, nullptr, 0, -1500) == 0,
          "signed EV step validation");
    check(sony2fuji_sony_property_options(&ev, nullptr, 0, 1, 1, 513, opts, 8, &ocount) == SONY2FUJI_STATUS_OK &&
              ocount == 5u && opts[0] == -2000 && opts[4] == 2000,
          "EV range options");
    check(std::string(sony2fuji_sony_property_table_text_at(table, 2u)) == "http://localhost:8080/liveviewstream",
          "text property read");

    int32_t locked = 0;
    int32_t failed = 0;
    sony2fuji_sony_property_table_focus_indication(table, &locked, &failed);
    check(locked == 1 && failed == 0, "0xd213=6 -> locked=1, failed=0");

    const uint16_t controls[]{0xd2e4u, 0xd2e5u, 0xd2dcu};
    const uint16_t ops[]{0x9207u};
    sony2fuji_sony_focus_target target = SONY2FUJI_SONY_FOCUS_TARGET_NONE;
    sony2fuji_sony_focus_unavailable_reason reason = SONY2FUJI_SONY_FOCUS_UNAVAILABLE_UNSUPPORTED;
    check(sony2fuji_sony_property_table_resolve_focus_target(table, controls, 3, ops, 1, 1, &target, &reason) == SONY2FUJI_STATUS_OK &&
              target == SONY2FUJI_SONY_FOCUS_TARGET_REMOTE_TOUCH && reason == SONY2FUJI_SONY_FOCUS_AVAILABLE,
          "resolve_focus_target -> REMOTE_TOUCH");
    check(sony2fuji_sony_property_table_can_cancel_touch_focus(table, controls, 3, ops, 1, 1) == 0,
          "can_cancel_touch_focus false without 0xd285=1");
    sony2fuji_sony_property_table_free(table);

    auto p_trail = p;
    p_trail.push_back(0u);
    check(sony2fuji_sony_parse_properties(p_trail.data(), p_trail.size(), 2, &table) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "trailing property bytes rejected");
}

void testContents0x923bAnd0x923cAnd0x1008() {
    uint32_t count = 99;
    const uint8_t tiny[2]{1, 2};
    check(sony2fuji_sony_parse_slot_photo_count(tiny, sizeof(tiny), &count) == SONY2FUJI_STATUS_OK && count == 0u,
          "0x923b < 4B -> 0");
    std::vector<uint8_t> max_slot(SONY2FUJI_SONY_SLOT_DATES_LIMIT, 0);
    max_slot[0] = 42u;
    check(sony2fuji_sony_parse_slot_photo_count(max_slot.data(), max_slot.size(), &count) == SONY2FUJI_STATUS_OK &&
              count == 42u,
          "0x923b 256 KiB accepted");
    max_slot.push_back(0u);
    check(sony2fuji_sony_parse_slot_photo_count(max_slot.data(), max_slot.size(), &count) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "0x923b > 256 KiB rejected");

    // 0x923c mobile page
    std::vector<uint8_t> page(144, 0);
    appendU32(page, 1u); // entry count
    appendU32(page, 0u);
    appendU32(page, 1001u); // content
    page.insert(page.end(), 20u, 0u);
    appendU64(page, 1700000000000ULL);
    page.insert(page.end(), 36u, 0u);
    appendU32(page, 0u); // shot marks
    appendU32(page, 1u); // files
    const std::string path = "/DCIM/100MSDCF/DSC00001.ARW";
    appendU32(page, 2u); // file id
    appendU32(page, static_cast<uint32_t>(path.size() + 1u));
    page.insert(page.end(), path.begin(), path.end());
    page.push_back(0u);
    appendU32(page, 0u);
    appendU64(page, 50000000ULL);
    page.insert(page.end(), 32u, 0u);
    appendU32(page, 0u);
    appendU32(page, 0u);
    appendU32(page, 0u);

    sony2fuji_sony_mobile_page* parsed_page = nullptr;
    check(sony2fuji_sony_parse_mobile_page(page.data(), page.size(), &parsed_page) == SONY2FUJI_STATUS_OK &&
              sony2fuji_sony_mobile_page_entry_count(parsed_page) == 1u &&
              sony2fuji_sony_mobile_page_cursor(parsed_page) == 1700000000000ULL &&
              sony2fuji_sony_mobile_page_asset_count(parsed_page) == 1u,
          "parse_mobile_page succeeds");
    sony2fuji_sony_mobile_asset_info asset_info{};
    const char* asset_name = nullptr;
    check(sony2fuji_sony_mobile_page_asset_at(parsed_page, 0u, &asset_info, &asset_name) == SONY2FUJI_STATUS_OK &&
              asset_info.content == 1001u && asset_info.file == 2u && asset_info.size == 50000000ULL &&
              std::string(asset_name) == "DSC00001.ARW",
          "mobile_page_asset_at");
    sony2fuji_sony_mobile_page_free(parsed_page);

    auto bad_page = page;
    bad_page.push_back(0u);
    check(sony2fuji_sony_parse_mobile_page(bad_page.data(), bad_page.size(), &parsed_page) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "mobile_page trailing byte rejected");

    // 0x1008 legacy object
    std::vector<uint8_t> leg;
    appendU32(leg, 0x10001u);
    appendU16(leg, 0x3801u);
    appendU16(leg, 0u);
    appendU32(leg, 123456u);
    leg.insert(leg.end(), 40u, 0u);
    appendPtpString(leg, "DSC00002.JPG");
    appendPtpString(leg, "20261125T010203");
    appendPtpString(leg, "20261125T010203");
    appendPtpString(leg, "");
    sony2fuji_sony_legacy_object* leg_obj = nullptr;
    check(sony2fuji_sony_parse_legacy_object(leg.data(), leg.size(), &leg_obj) == SONY2FUJI_STATUS_OK,
          "parse_legacy_object succeeds");
    sony2fuji_sony_legacy_object_info leg_info{};
    const char* lname = nullptr;
    const char* lcreated = nullptr;
    const char* lmod = nullptr;
    check(sony2fuji_sony_legacy_object_get(leg_obj, &leg_info, &lname, &lcreated, &lmod) == SONY2FUJI_STATUS_OK &&
              leg_info.storage == 0x10001u && leg_info.format == 0x3801u && leg_info.size == 123456ULL &&
              std::string(lname) == "DSC00002.JPG" && std::string(lcreated) == "20261125T010203",
          "legacy_object_get");
    sony2fuji_sony_legacy_object_free(leg_obj);
}

void testLiveViewAndProjection() {
    const uint32_t f_ok[4]{16u, 100u, 116u, 136u};
    sony2fuji_sony_live_frame_bounds bounds{};
    check(sony2fuji_sony_parse_live_frame_bounds(f_ok, SONY2FUJI_SONY_PTPIP_DATA_LIMIT, &bounds) == SONY2FUJI_STATUS_OK &&
              bounds.body_size == 236u && bounds.image_offset == 0u && bounds.image_length == 100u &&
              bounds.has_metadata == 1 && bounds.metadata_offset == 100u && bounds.metadata_length == 136u,
          "parse_live_frame_bounds valid");
    const uint32_t f_overlap[4]{16u, 100u, 20u, 10u};
    check(sony2fuji_sony_parse_live_frame_bounds(f_overlap, SONY2FUJI_SONY_PTPIP_DATA_LIMIT, &bounds) == SONY2FUJI_STATUS_INVALID_ARGUMENT,
          "parse_live_frame_bounds rejects overlapping regions");

    auto appendMetaBlock = [](std::vector<uint8_t>& m, uint32_t xmax, uint32_t ymax,
                              uint16_t count, uint16_t type, uint16_t state,
                              uint32_t cx, uint32_t cy, uint32_t h, uint32_t w) {
        appendU32(m, xmax);
        appendU32(m, ymax);
        appendU16(m, count);
        m.insert(m.end(), 6u, 0u);
        if (count > 0u) {
            appendU16(m, type);
            appendU16(m, state);
            appendU32(m, 0u);
            appendU32(m, cx);
            appendU32(m, cy);
            appendU32(m, h);
            appendU32(m, w);
        }
    };

    std::vector<uint8_t> m68;
    appendU16(m68, 0x68u);
    m68.insert(m68.end(), 0x28u - 2u, 0u);
    appendMetaBlock(m68, 1u, 1u, 0u, 0, 0, 0, 0, 0, 0);
    appendMetaBlock(m68, 100u, 50u, 1u, 1u, 2u, 10u, 20u, 4u, 6u);
    appendMetaBlock(m68, 100u, 50u, 1u, 2u, 1u, 30u, 40u, 8u, 12u);
    appendMetaBlock(m68, 100u, 50u, 1u, 5u, 1u, 50u, 5u, 2u, 3u);
    sony2fuji_sony_live_view_frame frames[8]{};
    uint32_t fcount = 0;
    check(sony2fuji_sony_parse_live_view_frames(m68.data(), m68.size(), frames, 8, &fcount) == SONY2FUJI_STATUS_OK &&
              fcount == 3u &&
              frames[0].kind == SONY2FUJI_SONY_LIVE_FRAME_FOCUS && frames[0].focused == 1 &&
              frames[1].kind == SONY2FUJI_SONY_LIVE_FRAME_FACE && frames[1].focused == 1 &&
              frames[2].kind == SONY2FUJI_SONY_LIVE_FRAME_TRACKING && frames[2].focused == 0,
          "parse_live_view_frames v0x68");

    std::vector<uint8_t> m64;
    appendU16(m64, 0x64u);
    m64.insert(m64.end(), 0x28u - 2u, 0u);
    appendMetaBlock(m64, 1u, 1u, 0u, 0, 0, 0, 0, 0, 0);
    appendMetaBlock(m64, 100u, 50u, 1u, 1u, 2u, 10u, 20u, 4u, 6u);
    check(sony2fuji_sony_parse_live_view_frames(m64.data(), m64.size(), frames, 8, &fcount) == SONY2FUJI_STATUS_OK &&
              fcount == 1u && frames[0].kind == SONY2FUJI_SONY_LIVE_FRAME_FOCUS,
          "parse_live_view_frames v0x64 decodes focus only");

    int32_t valid = 0;
    sony2fuji_sony_focus_tap_point tap{};
    check(sony2fuji_sony_focus_point_from_tap(160.0, 120.0, 640.0, 480.0, 640.0, 480.0, &valid, &tap) == SONY2FUJI_STATUS_OK &&
              valid == 1 && tap.x == 160 && tap.y == 120 && tap.packed == ((160u << 16u) | 120u),
          "focus_point_from_tap quarter point");
    check(sony2fuji_sony_focus_point_from_tap(320.0, 40.0, 640.0, 640.0, 640.0, 480.0, &valid, &tap) == SONY2FUJI_STATUS_OK &&
              valid == 0,
          "focus_point_from_tap ignores letterbox bar");
    check(sony2fuji_sony_focus_point_from_tap(640.0, 560.0, 640.0, 640.0, 640.0, 480.0, &valid, &tap) == SONY2FUJI_STATUS_OK &&
              valid == 1 && tap.x == 639 && tap.y == 479,
          "focus_point_from_tap clamps bottom-right to 639x479");

    sony2fuji_sony_live_view_frame track{SONY2FUJI_SONY_LIVE_FRAME_TRACKING, 0, 0.5, 0.5, 0.10, 0.127};
    sony2fuji_sony_focus_overlay_box box{};
    check(sony2fuji_sony_compute_focus_overlay_box(&track, 0.0, 0.0, 430.0, 286.0, &box) == SONY2FUJI_STATUS_OK &&
              box.is_normalized_square == 1 && std::abs(box.width - box.height) < 1e-6,
          "focus_overlay_box normalizes <=1.35 aspect to square");
    double ratio = 0.0;
    int32_t rvalid = 0;
    check(sony2fuji_sony_normalized_focus_square_ratio(&track, 430.0, 286.0, &rvalid, &ratio) == SONY2FUJI_STATUS_OK &&
              rvalid == 1,
          "normalized_focus_square_ratio valid");
    double side = 0.0;
    check(sony2fuji_sony_tap_focus_side(430.0, 286.0, 34.0, 52.0, 20.0, 1, ratio, &side) == SONY2FUJI_STATUS_OK &&
              std::abs(side - box.width) < 1e-3,
          "tap_focus_side matches normalized square");
}

void testFocusStateMachine() {
    sony2fuji_sony_focus_state state{};
    check(sony2fuji_sony_focus_state_init(&state) == SONY2FUJI_STATUS_OK &&
              state.version == SONY2FUJI_SONY_FOCUS_STATE_VERSION &&
              state.struct_size == sizeof(sony2fuji_sony_focus_state),
          "focus_state_init");

    sony2fuji_sony_focus_render_decision decision{};
    check(sony2fuji_sony_focus_state_resolve_render(&state, 0, 0, 430, 286, 34, 52, 20, &decision) == SONY2FUJI_STATUS_OK &&
              decision.mode == SONY2FUJI_SONY_FOCUS_RENDER_NONE,
          "initial render is NONE");

    // Tap at t=1000 -> focus_busy=1, tap_active=1, no deadline yet
    check(sony2fuji_sony_focus_state_on_tap(&state, 0.5, 0.5, 320, 240, 1000) == SONY2FUJI_STATUS_OK &&
              state.focus_busy == 1 && state.tap_active == 1 && state.has_pending_deadline == 0,
          "on_tap sets focus_busy=1 without deadline");
    const uint64_t gen1 = state.tap_generation;

    // Live frames arriving while focus_busy=1 are suppressed
    sony2fuji_sony_live_view_frame track{SONY2FUJI_SONY_LIVE_FRAME_TRACKING, 1, 0.5, 0.5, 0.10, 0.127};
    check(sony2fuji_sony_focus_state_on_live_frame(&state, &track, 1, 430, 286) == SONY2FUJI_STATUS_OK &&
              state.has_live_frames == 0 && state.tap_active == 1,
          "live frames suppressed while focus_busy=1");

    // Tick at t=5000 while focus_busy=1 must NOT clear tap_active
    check(sony2fuji_sony_focus_state_on_tick(&state, 5000) == SONY2FUJI_STATUS_OK &&
              state.tap_active == 1,
          "on_tick does not expire while focus_busy=1");

    // Finish focus at t=1200 -> deadline = 3000ms
    check(sony2fuji_sony_focus_state_on_focus_finished(&state, 1, 1, 1200) == SONY2FUJI_STATUS_OK &&
              state.focus_busy == 0 && state.tap_focus_locked == 1 &&
              state.has_pending_deadline == 1 && state.tap_deadline_ms == 3000,
          "on_focus_finished schedules 1800ms deadline");
    check(sony2fuji_sony_focus_state_resolve_render(&state, 0, 0, 430, 286, 34, 52, 20, &decision) == SONY2FUJI_STATUS_OK &&
              decision.mode == SONY2FUJI_SONY_FOCUS_RENDER_TAP_RETICLE &&
              decision.effective_focus_locked == 1,
          "render TAP_RETICLE locked");

    // Tick at 2999 keeps reticle
    check(sony2fuji_sony_focus_state_on_tick(&state, 2999) == SONY2FUJI_STATUS_OK && state.tap_active == 1,
          "reticle stays active at 1799ms");
    // Stale generation timeout ignored
    check(sony2fuji_sony_focus_state_on_timeout(&state, gen1 - 1, 5000) == SONY2FUJI_STATUS_OK && state.tap_active == 1,
          "stale generation timeout ignored");
    // Exact 1800ms clears reticle
    check(sony2fuji_sony_focus_state_on_timeout(&state, gen1, 3000) == SONY2FUJI_STATUS_OK &&
              state.tap_active == 0 && state.has_pending_deadline == 0,
          "exact 1800ms expires reticle");

    // New tap + live frame replacement + ratio learning
    check(sony2fuji_sony_focus_state_on_tap(&state, 0.25, 0.25, 160, 120, 3100) == SONY2FUJI_STATUS_OK &&
              sony2fuji_sony_focus_state_on_focus_finished(&state, 1, 0, 3200) == SONY2FUJI_STATUS_OK &&
              sony2fuji_sony_focus_state_on_live_frame(&state, &track, 1, 430, 286) == SONY2FUJI_STATUS_OK,
          "live frame arrives after focus finished");
    check(state.has_live_frames == 1 && state.tap_active == 0 && state.has_last_square_ratio == 1,
          "live frame replaces tap reticle and learns square ratio");
    check(sony2fuji_sony_focus_state_resolve_render(&state, 0, 0, 430, 286, 34, 52, 20, &decision) == SONY2FUJI_STATUS_OK &&
              decision.mode == SONY2FUJI_SONY_FOCUS_RENDER_LIVE_FRAMES,
          "render mode LIVE_FRAMES");

    // Properties cancel drop / focus failed clears tap_focus_locked
    check(sony2fuji_sony_focus_state_on_properties(&state, 1, 0, 0) == SONY2FUJI_STATUS_OK &&
              sony2fuji_sony_focus_state_on_tap(&state, 0.5, 0.5, 320, 240, 4000) == SONY2FUJI_STATUS_OK &&
              sony2fuji_sony_focus_state_on_focus_finished(&state, 1, 1, 4100) == SONY2FUJI_STATUS_OK &&
              state.tap_focus_locked == 1 &&
              sony2fuji_sony_focus_state_on_properties(&state, 0, 0, 0) == SONY2FUJI_STATUS_OK &&
              state.tap_focus_locked == 0,
          "dropping can_cancel clears tap_focus_locked");

    // Capture/param start clears tap_focus_locked
    check(sony2fuji_sony_focus_state_on_focus_finished(&state, 1, 1, 4200) == SONY2FUJI_STATUS_OK &&
              sony2fuji_sony_focus_state_on_capture_or_param_start(&state) == SONY2FUJI_STATUS_OK &&
              state.tap_focus_locked == 0,
          "capture_or_param_start clears tap_focus_locked");

    // Cancel start clears tap_active and live frames
    check(sony2fuji_sony_focus_state_on_cancel_start(&state) == SONY2FUJI_STATUS_OK &&
              state.focus_busy == 1 && state.tap_active == 0 && state.has_live_frames == 0,
          "cancel_start clears active overlays");
    check(sony2fuji_sony_focus_state_on_focus_finished(&state, 0, 0, 4300) == SONY2FUJI_STATUS_OK &&
              state.focus_busy == 0 && state.tap_active == 0,
          "failed focus finish clears focus_busy and tap_active");

    // Live changed off clears overlays while preserving learned ratio; full reset clears learned ratio
    check(sony2fuji_sony_focus_state_on_live_changed(&state, 0) == SONY2FUJI_STATUS_OK &&
              state.has_last_square_ratio == 1 &&
              sony2fuji_sony_focus_state_reset(&state, 0) == SONY2FUJI_STATUS_OK &&
              state.has_last_square_ratio == 0,
          "live_changed preserves learned ratio, reset(0) clears it");
}

} // namespace

int main() {
    testPtpipFraming();
    testCredentialsAndHeaders();
    testDeviceInfoAndRemoteDescriptor();
    testPropertiesAndFocusPolicy();
    testContents0x923bAnd0x923cAnd0x1008();
    testLiveViewAndProjection();
    testFocusStateMachine();
    if (g_failures != 0) {
        std::fprintf(stderr, "sony_ptpip_tests failed: %d assertions\n", g_failures);
        return 1;
    }
    std::printf("sony_ptpip_tests passed\n");
    return 0;
}
