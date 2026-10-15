// CUA acceptance helper for the live Simplified Chinese crop workspace with
// precise controls expanded. Feed a fresh, full app.getAXState() result; this
// does not replace native input or verify VoiceOver announcements.
function checkCropAccessibility(state) {
    if (typeof state !== "string" || !state.startsWith("Window:")) {
        throw new Error("Expected a fresh full CUA native AX dump, not a diff or snapshot model");
    }
    const rows = state.split("\n").filter(line => /^\s*\d+\s/.test(line));
    const byID = id => rows.filter(line => {
        const match = line.match(/ID: ([^,]+)/);
        return match && match[1] === id;
    });
    const names = {
        topLeft: "裁切左上角", top: "裁切上边", topRight: "裁切右上角",
        left: "裁切左边", move: "裁切选区", right: "裁切右边",
        bottomLeft: "裁切左下角", bottom: "裁切下边", bottomRight: "裁切右下角"
    };
    const checks = [];
    for (const [handle, label] of Object.entries(names)) {
        const id = "geometry.crop." + handle;
        const matches = byID(id);
        const actual = matches[0]?.match(/Description: ([^,]+)/)?.[1];
        const adjustable = matches[0]?.includes("Increment") && matches[0]?.includes("Decrement");
        checks.push({ id, pass: matches.length === 1 && actual === label && adjustable,
            actual, count: matches.length, adjustable });
    }
    for (const parameter of ["cropX", "cropY", "cropWidth", "cropHeight"]) {
        for (const control of ["value", "slider", "reset"]) {
            const id = "geometry." + control + "." + parameter;
            const matches = byID(id);
            const role = control === "value" ? /文本栏/ : control === "reset" ? /按钮/ : /settable, float|滑块/;
            checks.push({ id, pass: matches.length === 1 && role.test(matches[0]), count: matches.length });
        }
    }
    const header = byID("geometry.preciseCrop");
    checks.push({ id: "geometry.preciseCrop",
        pass: header.length === 1 && /显示三角形|disclosure triangle/i.test(header[0]), count: header.length });
    return { count: checks.length, passed: checks.filter(check => check.pass).length,
        failures: checks.filter(check => !check.pass) };
}

function assertCropAccessibility(state) {
    const report = checkCropAccessibility(state);
    if (report.passed !== report.count) throw new Error(JSON.stringify(report));
    return report;
}
