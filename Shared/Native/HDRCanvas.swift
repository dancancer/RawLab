import SwiftUI
import MetalKit
import Combine

final class HDRDisplayState: ObservableObject {
    @Published var mode=HDRPreviewMode.automatic
    @Published var falseColor=false
    @Published var retry=0
    @Published private(set) var headroom=1.0
    @Published private(set) var displayFailed=false
    func update(headroom: Double, failed: Bool) {
        if abs(self.headroom-headroom)>0.005 { self.headroom=headroom }
        if displayFailed != failed { displayFailed=failed }
    }
}

struct HDRCanvas: View {
    let presentation: HDRDisplayImage
    @ObservedObject var state: HDRDisplayState
    var body: some View {
        ZStack {
            Image(decorative:presentation.sdrImage,scale:1).resizable().interpolation(.high)
            HDRMetalCanvas(presentation:presentation,state:state).id(state.retry)
        }.allowsHitTesting(false).accessibilityHidden(true)
    }
}

private final class HDRCanvasRenderer: NSObject,MTKViewDelegate {
    var presentation: HDRDisplayImage
    let state: HDRDisplayState
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?
    private var uploaded: ObjectIdentifier?
    private var parameters: HDRDisplayParameters?

    init(presentation: HDRDisplayImage,state: HDRDisplayState,device: MTLDevice) throws {
        self.presentation=presentation; self.state=state
        guard let queue=device.makeCommandQueue() else { throw HDRDisplayFailure.invalidBuffer }
        self.queue=queue
        let source="""
        #include <metal_stdlib>
        using namespace metal;
        struct Vertex { float4 position [[position]]; float2 uv; };
        vertex Vertex hdr_vertex(uint i [[vertex_id]]) {
            const float2 p[3]={float2(-1,-1),float2(3,-1),float2(-1,3)};
            Vertex v; v.position=float4(p[i],0,1); v.uv=float2((p[i].x+1)*0.5,(1-p[i].y)*0.5); return v;
        }
        fragment half4 hdr_fragment(Vertex v [[stage_in]],texture2d<half> image [[texture(0)]]) {
            constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
            return image.sample(s,v.uv);
        }
        """
        let library=try device.makeLibrary(source:source,options:nil)
        let descriptor=MTLRenderPipelineDescriptor()
        descriptor.vertexFunction=library.makeFunction(name:"hdr_vertex")
        descriptor.fragmentFunction=library.makeFunction(name:"hdr_fragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        pipeline=try device.makeRenderPipelineState(descriptor:descriptor)
        super.init()
    }

    func mtkView(_ view: MTKView,drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        #if os(macOS)
        guard NSApp.isActive,view.window?.isVisible == true else { texture=nil; uploaded=nil; view.releaseDrawables(); return }
        let headroom=Double(view.window?.screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1)
        #else
        guard UIApplication.shared.applicationState == .active,view.window != nil else { texture=nil; uploaded=nil; view.releaseDrawables(); return }
        let headroom=Double(view.window?.windowScene?.screen.currentEDRHeadroom ?? 1)
        #endif
        let desired=HDRDisplayParameters(headroom:headroom,mode:state.mode,falseColor:state.falseColor)
        do {
            if uploaded != ObjectIdentifier(presentation) || parameters != desired {
                let data=try presentation.rgba16F(desired)
                let desc=MTLTextureDescriptor.texture2DDescriptor(pixelFormat:.rgba16Float,
                    width:presentation.width,height:presentation.height,mipmapped:false)
                desc.usage = .shaderRead; desc.storageMode = .shared
                guard let replacement=view.device?.makeTexture(descriptor:desc) else { throw HDRDisplayFailure.invalidBuffer }
                data.withUnsafeBytes { bytes in
                    replacement.replace(region:MTLRegionMake2D(0,0,desc.width,desc.height),mipmapLevel:0,
                        withBytes:bytes.baseAddress!,bytesPerRow:desc.width*8)
                }
                texture=replacement; parameters=desired; uploaded=ObjectIdentifier(presentation)
            }
            guard let texture,let drawable=view.currentDrawable,let pass=view.currentRenderPassDescriptor,
                  let command=queue.makeCommandBuffer(),let encoder=command.makeRenderCommandEncoder(descriptor:pass) else {
                throw HDRDisplayFailure.invalidBuffer
            }
            encoder.setRenderPipelineState(pipeline); encoder.setFragmentTexture(texture,index:0)
            encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:3); encoder.endEncoding()
            let frame=ObjectIdentifier(presentation)
            command.addCompletedHandler { [weak self,weak view] completed in
                guard completed.status == .error else { return }
                DispatchQueue.main.async {
                    guard let self,let view,self.uploaded==frame,self.parameters==desired else { return }
                    view.isHidden=true; view.isPaused=true; view.releaseDrawables()
                    self.texture=nil; self.uploaded=nil; self.parameters=nil
                    self.state.update(headroom:headroom,failed:true)
                }
            }
            command.present(drawable); command.commit()
            view.isHidden=false
            publish(headroom:headroom,failed:false)
        } catch {
            view.isHidden=true; view.releaseDrawables(); texture=nil; uploaded=nil; parameters=nil
            publish(headroom:headroom,failed:true)
        }
    }
    private func publish(headroom: Double,failed: Bool) {
        guard abs(state.headroom-headroom)>0.005 || state.displayFailed != failed else { return }
        DispatchQueue.main.async { [weak state] in state?.update(headroom:headroom,failed:failed) }
    }
}

private func makeHDRMetalView(presentation: HDRDisplayImage,state: HDRDisplayState) -> (MTKView,HDRCanvasRenderer?) {
    let view=MTKView(frame:.zero,device:MTLCreateSystemDefaultDevice())
    view.colorPixelFormat = .rgba16Float
    #if os(macOS)
    view.colorspace=CGColorSpace(name:CGColorSpace.extendedLinearDisplayP3)
    #endif
    view.framebufferOnly=true; view.preferredFramesPerSecond=30; view.clearColor=MTLClearColorMake(0,0,0,1)
    if let layer=view.layer as? CAMetalLayer {
        layer.colorspace=CGColorSpace(name:CGColorSpace.extendedLinearDisplayP3)
        layer.wantsExtendedDynamicRangeContent=true; layer.edrMetadata=nil
    }
    let renderer=view.device.flatMap { try? HDRCanvasRenderer(presentation:presentation,state:state,device:$0) }
    view.delegate=renderer
    if renderer==nil {
        view.isHidden=true
        DispatchQueue.main.async { state.update(headroom:1,failed:true) }
    }
    return (view,renderer)
}

#if os(macOS)
private struct HDRMetalCanvas: NSViewRepresentable {
    let presentation: HDRDisplayImage
    let state: HDRDisplayState
    final class Coordinator { var renderer: HDRCanvasRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> MTKView {
        let (view,renderer)=makeHDRMetalView(presentation:presentation,state:state)
        context.coordinator.renderer=renderer; return view
    }
    func updateNSView(_ view: MTKView,context: Context) { context.coordinator.renderer?.presentation=presentation }
    static func dismantleNSView(_ view: MTKView,coordinator: Coordinator) {
        view.isPaused=true; view.delegate=nil; view.releaseDrawables(); coordinator.renderer=nil
    }
}
#else
private struct HDRMetalCanvas: UIViewRepresentable {
    let presentation: HDRDisplayImage
    let state: HDRDisplayState
    final class Coordinator { var renderer: HDRCanvasRenderer? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> MTKView {
        let (view,renderer)=makeHDRMetalView(presentation:presentation,state:state)
        context.coordinator.renderer=renderer; return view
    }
    func updateUIView(_ view: MTKView,context: Context) { context.coordinator.renderer?.presentation=presentation }
    static func dismantleUIView(_ view: MTKView,coordinator: Coordinator) {
        view.isPaused=true; view.delegate=nil; view.releaseDrawables(); coordinator.renderer=nil
    }
}
#endif
