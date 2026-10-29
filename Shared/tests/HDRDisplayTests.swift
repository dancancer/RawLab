import Foundation

@main enum HDRDisplayTests {
    static func require(_ value: @autoclosure () -> Bool,_ message: String) { if !value() { fatalError(message) } }
    static func main() throws {
        let hdr=SIMD3<Float>(4,4,4),sdr=SIMD3<Float>(0.5,0.5,0.5)
        for headroom in [1.0,2,4,8] {
            let result=try HDRDisplayMath.pixel(hdr:hdr,sdr:sdr,contentHeadroom:4,
                parameters:HDRDisplayParameters(headroom:headroom))
            let expected: Float=headroom==1 ? 0.5 : Float(min(4,headroom))
            require(abs(result.x-expected)<1e-5 && abs(result.y-expected)<1e-5 && abs(result.z-expected)<1e-5,
                "display capacity/SDR fallback is wrong")
        }
        let white=SIMD3<Float>(1,1,1)
        let kept=try HDRDisplayMath.pixel(hdr:white,sdr:sdr,contentHeadroom:8,parameters:.init(headroom:2))
        require(abs(kept.x-1)<1e-5 && abs(kept.y-1)<1e-5,"reference white changed")
        var compatibility=HDRDisplayParameters(headroom:8); compatibility.mode = .sdr
        let preview=try HDRDisplayMath.pixel(hdr:hdr,sdr:sdr,contentHeadroom:4,parameters:compatibility)
        require(abs(preview.x-0.5)<1e-5,"SDR preview used HDR pixels")
        let input: [Float]=[0,0,0,1,1,1,2,2,2,4,4,4]
        let before=input
        let stats=try input.withUnsafeBufferPointer { try HDRStatistics.analyze($0,width:4,height:1,stride:12) }
        require(stats.bins.reduce(0,+)==4 && stats.aboveWhite==2 && stats.headroom==4,
            "float HDR statistics differ: count=\(stats.bins.reduce(0,+)), above=\(stats.aboveWhite), headroom=\(stats.headroom)")
        for h in [1.0,2,4,8] {
            _ = try HDRDisplayMath.pixel(hdr:hdr,sdr:sdr,contentHeadroom:4,parameters:.init(headroom:h))
        }
        require(input==before,"monitoring altered working pixels")
        let packed=try HDRDisplayMath.half(SIMD3<Float>(-0.25,2,4))
        require(Float(Float16(bitPattern:packed[0])) == -0.25 && Float(Float16(bitPattern:packed[1]))==2,
            "FP16 pack clipped negative or super-white values")
        do { _ = try HDRDisplayMath.half(SIMD3<Float>(70000,1,1)); fatalError("FP16 silently overflowed") }
        catch HDRDisplayFailure.unrepresentable {}
        print("PASS HDR float statistics, reference white, display-only mapping and finite FP16")
    }
}
