// Offline renderer for the Slang compute shader (compiled to Metal source).
// Pass 1 (computeMain) renders the scene in linear HDR into a mip-mapped float
// texture; pass 2 (postMain) applies the lens and film from it into the output.
// usage: render <shader.metal> <out.png|out.gif> <width> <height> <time> [frames] [dt] [ss]
import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

let args = CommandLine.arguments
guard args.count >= 6 else {
    print("usage: render <shader.metal> <out.png|out.gif> <w> <h> <time> [frames] [dt] [ss]")
    exit(1)
}
let source = try! String(contentsOfFile: args[1], encoding: .utf8)
let outPath = args[2]
let width = Int(args[3])!, height = Int(args[4])!
let t0 = Float(args[5])!
let frames = args.count > 6 ? Int(args[6])! : 1
let dt = args.count > 7 ? Float(args[7])! : 0.1
let ss = args.count > 8 ? Int(args[8])! : 2

let device = MTLCreateSystemDefaultDevice()!
let library = try! device.makeLibrary(source: source, options: nil)
let scenePipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "computeMain")!)
let postPipeline = try! device.makeComputePipelineState(function: library.makeFunction(name: "postMain")!)
let queue = device.makeCommandQueue()!

let rw = width * ss, rh = height * ss
let sceneDesc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: rw, height: rh, mipmapped: true)
sceneDesc.usage = [.shaderRead, .shaderWrite]
let sceneTexture = device.makeTexture(descriptor: sceneDesc)!
let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: rw, height: rh, mipmapped: false)
desc.usage = [.shaderRead, .shaderWrite]
let texture = device.makeTexture(descriptor: desc)!
let samplerDesc = MTLSamplerDescriptor()
samplerDesc.minFilter = .linear
samplerDesc.magFilter = .linear
samplerDesc.mipFilter = .linear
samplerDesc.sAddressMode = .clampToEdge
samplerDesc.tAddressMode = .clampToEdge
let sampler = device.makeSamplerState(descriptor: samplerDesc)!

func renderFrame(_ time: Float) -> CGImage {
    var params: [Float] = [Float(rw), Float(rh), time, 0]
    let cmd = queue.makeCommandBuffer()!
    let grid = MTLSize(width: rw, height: rh, depth: 1)
    let group = MTLSize(width: 8, height: 8, depth: 1)
    // Pass 1: the scene. (Both kernels declare every binding; the unused ones
    // get the other texture.)
    let enc = cmd.makeComputeCommandEncoder()!
    enc.setComputePipelineState(scenePipeline)
    enc.setBytes(&params, length: 16, index: 0)
    enc.setTexture(sceneTexture, index: 0)
    enc.setTexture(texture, index: 1)
    enc.setSamplerState(sampler, index: 0)
    enc.dispatchThreads(grid, threadsPerThreadgroup: group)
    enc.endEncoding()
    let blit = cmd.makeBlitCommandEncoder()!
    blit.generateMipmaps(for: sceneTexture)
    blit.endEncoding()
    // Pass 2: lens and film.
    let post = cmd.makeComputeCommandEncoder()!
    post.setComputePipelineState(postPipeline)
    post.setBytes(&params, length: 16, index: 0)
    post.setTexture(texture, index: 0)
    post.setTexture(sceneTexture, index: 1)
    post.setSamplerState(sampler, index: 0)
    post.dispatchThreads(grid, threadsPerThreadgroup: group)
    post.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()

    var bytes = [UInt8](repeating: 0, count: rw * rh * 4)
    texture.getBytes(&bytes, bytesPerRow: rw * 4, from: MTLRegionMake2D(0, 0, rw, rh), mipmapLevel: 0)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = CGImageAlphaInfo.noneSkipLast.rawValue
    let big = CGContext(data: &bytes, width: rw, height: rh, bitsPerComponent: 8, bytesPerRow: rw * 4,
                        space: cs, bitmapInfo: info)!.makeImage()!
    if ss == 1 { return big }
    let small = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                          space: cs, bitmapInfo: info)!
    small.interpolationQuality = .high
    small.draw(big, in: CGRect(x: 0, y: 0, width: width, height: height))
    return small.makeImage()!
}

let isGif = outPath.hasSuffix(".gif")
let type = isGif ? UTType.gif : UTType.png
let url = URL(fileURLWithPath: outPath) as CFURL
let dest = CGImageDestinationCreateWithURL(url, type.identifier as CFString, isGif ? frames : 1, nil)!
if isGif {
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
}
let start = Date()
for i in 0..<(isGif ? frames : 1) {
    let img = renderFrame(t0 + Float(i) * dt)
    let props = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: dt]] as CFDictionary
    CGImageDestinationAddImage(dest, img, isGif ? props : nil)
}
CGImageDestinationFinalize(dest)
print(String(format: "wrote %@ in %.2fs", outPath, Date().timeIntervalSince(start)))
