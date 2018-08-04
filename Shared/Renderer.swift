
import Foundation
import MetalKit
import simd

enum TextureIndex: Int {
    case baseColor
    case metallic
    case roughness
    case normal
    case emissive
    case irradiance = 9
}

enum VertexBufferIndex: Int {
    case attributes
    case uniforms
}

enum FragmentBufferIndex: Int {
    case uniforms
}

struct Uniforms {
    let modelMatrix: float4x4
    let modelViewProjectionMatrix: float4x4
    let normalMatrix: float3x3
    let cameraPosition: float3
    let lightDirection: float3
    let lightPosition: float3
    
    init(modelMatrix: float4x4, viewMatrix: float4x4, projectionMatrix: float4x4,
         cameraPosition: float3, lightDirection: float3, lightPosition: float3)
    {
        self.modelMatrix = modelMatrix
        self.modelViewProjectionMatrix = projectionMatrix * viewMatrix * modelMatrix
        self.normalMatrix = modelMatrix.normalMatrix
        self.cameraPosition = cameraPosition
        self.lightDirection = lightDirection
        self.lightPosition = lightPosition
    }
}

class Material {
    var baseColor: MTLTexture?
    var metallic: MTLTexture?
    var roughness: MTLTexture?
    var normal: MTLTexture?
    var emissive: MTLTexture?
    
    func texture(for semantic: MDLMaterialSemantic, in material: MDLMaterial?, textureLoader: MTKTextureLoader) -> MTLTexture? {
        guard let materialProperty = material?.property(with: semantic) else { return nil }
        guard let sourceTexture = materialProperty.textureSamplerValue?.texture else { return nil }
        let wantMips = materialProperty.semantic != .tangentSpaceNormal
        let options: [MTKTextureLoader.Option : Any] = [ .generateMipmaps : wantMips ]
        return try? textureLoader.newTexture(texture: sourceTexture, options: options)
    }

    init(material sourceMaterial: MDLMaterial?, textureLoader: MTKTextureLoader) {
        baseColor = texture(for: .baseColor, in: sourceMaterial, textureLoader: textureLoader)
        metallic = texture(for: .metallic, in: sourceMaterial, textureLoader: textureLoader)
        roughness = texture(for: .roughness, in: sourceMaterial, textureLoader: textureLoader)
        normal = texture(for: .tangentSpaceNormal, in: sourceMaterial, textureLoader: textureLoader)
        emissive = texture(for: .emission, in: sourceMaterial, textureLoader: textureLoader)
    }
}

class Node {
    var modelMatrix: float4x4
    let mesh: MTKMesh
    let materials: [Material]
    
    init(mesh: MTKMesh, materials: [Material]) {
        assert(mesh.submeshes.count == materials.count)
        
        modelMatrix = matrix_identity_float4x4
        self.mesh = mesh
        self.materials = materials
    }
}

class Renderer: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let renderPipeline: MTLRenderPipelineState
    let depthStencilState: MTLDepthStencilState
    let vertexDescriptor: MDLVertexDescriptor
    
    let textureLoader: MTKTextureLoader
    let defaultTexture: MTLTexture
    let defaultNormalMap: MTLTexture
    let irradianceCubeMap: MTLTexture

    var nodes = [Node]()

    var viewMatrix = matrix_identity_float4x4
    var projectionMatrix = matrix_identity_float4x4
    var cameraWorldPosition = float3(0, 0, 3)
    var lightWorldDirection = float3(0, 1, 0)
    var lightWorldPosition = float3(0, 5, 0)
    var time: Float = 0
    
    init(view: MTKView, device: MTLDevice) {
        self.device = device
        commandQueue = device.makeCommandQueue()!
        vertexDescriptor = Renderer.buildVertexDescriptor(device: device)
        renderPipeline = Renderer.buildPipeline(device: device, view: view, vertexDescriptor: vertexDescriptor)
        depthStencilState = Renderer.buildDepthStencilState(device: device)
        textureLoader = MTKTextureLoader(device: device)
        (defaultTexture, defaultNormalMap) = Renderer.buildDefaultTextures(device: device)
        irradianceCubeMap = Renderer.buildEnvironmentTexture("garage_pmrem.ktx", device: device)
        super.init()
        
        guard let modelURL = Bundle.main.url(forResource: "scene", withExtension: "obj") else {
            fatalError("Could not find model file in app bundle")
        }
        buildScene(url: modelURL, device: device, vertexDescriptor: vertexDescriptor)
    }
    
    static func buildVertexDescriptor(device: MTLDevice) -> MDLVertexDescriptor {
        let vertexDescriptor = MDLVertexDescriptor()
        vertexDescriptor.attributes[0] = MDLVertexAttribute(name: MDLVertexAttributePosition,
                                                            format: .float3,
                                                            offset: 0,
                                                            bufferIndex: VertexBufferIndex.attributes.rawValue)
        vertexDescriptor.attributes[1] = MDLVertexAttribute(name: MDLVertexAttributeNormal,
                                                            format: .float3,
                                                            offset: MemoryLayout<Float>.size * 3,
                                                            bufferIndex: VertexBufferIndex.attributes.rawValue)
        vertexDescriptor.attributes[2] = MDLVertexAttribute(name: MDLVertexAttributeTangent,
                                                            format: .float3,
                                                            offset: MemoryLayout<Float>.size * 6,
                                                            bufferIndex: VertexBufferIndex.attributes.rawValue)
        vertexDescriptor.attributes[3] = MDLVertexAttribute(name: MDLVertexAttributeTextureCoordinate,
                                                            format: .float2,
                                                            offset: MemoryLayout<Float>.size * 9,
                                                            bufferIndex: VertexBufferIndex.attributes.rawValue)
        vertexDescriptor.layouts[VertexBufferIndex.attributes.rawValue] = MDLVertexBufferLayout(stride: MemoryLayout<Float>.size * 11)
        return vertexDescriptor
    }
    
    static func buildPipeline(device: MTLDevice, view: MTKView, vertexDescriptor: MDLVertexDescriptor) -> MTLRenderPipelineState {
        guard let library = device.makeDefaultLibrary() else {
            fatalError("Could not load default library from main bundle")
        }
        
        let vertexFunction = library.makeFunction(name: "vertex_main")
        let fragmentFunction = library.makeFunction(name: "fragment_main")
        
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        
        pipelineDescriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = view.depthStencilPixelFormat
        pipelineDescriptor.sampleCount = view.sampleCount
        
        let mtlVertexDescriptor = MTKMetalVertexDescriptorFromModelIO(vertexDescriptor)
        pipelineDescriptor.vertexDescriptor = mtlVertexDescriptor
        
        do {
            return try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        } catch {
            fatalError("Could not create render pipeline state object: \(error)")
        }
    }
    
    static func buildDepthStencilState(device: MTLDevice) -> MTLDepthStencilState {
        let depthStencilDescriptor = MTLDepthStencilDescriptor()
        depthStencilDescriptor.depthCompareFunction = .less
        depthStencilDescriptor.isDepthWriteEnabled = true
        return device.makeDepthStencilState(descriptor: depthStencilDescriptor)!
    }
    
    static func buildDefaultTextures(device: MTLDevice) -> (MTLTexture, MTLTexture) {
        let bounds = MTLRegionMake2D(0, 0, 1, 1)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                                                                  width: bounds.size.width,
                                                                  height: bounds.size.height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        let defaultTexture = device.makeTexture(descriptor: descriptor)!
        let defaultColor: [UInt8] = [ 0, 0, 0, 255 ]
        defaultTexture.replace(region: bounds, mipmapLevel: 0, withBytes: defaultColor, bytesPerRow: 4)
        let defaultNormalMap = device.makeTexture(descriptor: descriptor)!
        let defaultNormal: [UInt8] = [ 127, 127, 255, 255 ]
        defaultNormalMap.replace(region: bounds, mipmapLevel: 0, withBytes: defaultNormal, bytesPerRow: 4)
        return (defaultTexture, defaultNormalMap)
    }
    
    static func buildEnvironmentTexture(_ name: String, device:MTLDevice) -> MTLTexture {
        let textureLoader = MTKTextureLoader(device: device)
        let options: [MTKTextureLoader.Option : Any] = [:]
        do {
            let textureURL = Bundle.main.url(forResource: name, withExtension: nil)!
            let texture = try textureLoader.newTexture(URL: textureURL, options: options)
            return texture
        } catch {
            fatalError("Could not load irradiance map from asset catalog: \(error)")
        }
    }
    
    func buildScene(url: URL, device: MTLDevice, vertexDescriptor: MDLVertexDescriptor) {
        let bufferAllocator = MTKMeshBufferAllocator(device: device)
        let asset = MDLAsset(url: url, vertexDescriptor: nil, bufferAllocator: bufferAllocator)
        
        asset.loadTextures()
        
        for sourceMesh in asset.childObjects(of: MDLMesh.self) as! [MDLMesh] {
            sourceMesh.addOrthTanBasis(forTextureCoordinateAttributeNamed: MDLVertexAttributeTextureCoordinate,
                                       normalAttributeNamed: MDLVertexAttributeNormal,
                                       tangentAttributeNamed: MDLVertexAttributeTangent)
            sourceMesh.vertexDescriptor = vertexDescriptor
        }
        
        guard let (sourceMeshes, meshes) = try? MTKMesh.newMeshes(asset: asset, device: device) else {
            fatalError("Could not convert ModelIO meshes to MetalKit meshes")
        }

        for (sourceMesh, mesh) in zip(sourceMeshes, meshes) {
            var materials = [Material]()
            for sourceSubmesh in sourceMesh.submeshes as! [MDLSubmesh] {
                let material = Material(material: sourceSubmesh.material, textureLoader: textureLoader)
                materials.append(material)
            }
            let node = Node(mesh: mesh, materials: materials)
            nodes.append(node)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
    }
    
    func updateScene(view: MTKView) {
        time += 1 / Float(view.preferredFramesPerSecond)
        
        let aspectRatio = Float(view.drawableSize.width / view.drawableSize.height)
        projectionMatrix = float4x4(perspectiveProjectionFov: Float.pi / 3, aspectRatio: aspectRatio, nearZ: 0.1, farZ: 100)

        cameraWorldPosition = viewMatrix.inverse[3].xyz
        
        lightWorldPosition = cameraWorldPosition
        lightWorldDirection = normalize(cameraWorldPosition)
    }
    
    func bindTextures(_ material: Material, _ commandEncoder: MTLRenderCommandEncoder) {
        commandEncoder.setFragmentTexture(material.baseColor ?? defaultTexture, index: TextureIndex.baseColor.rawValue)
        commandEncoder.setFragmentTexture(material.metallic ?? defaultTexture, index: TextureIndex.metallic.rawValue)
        commandEncoder.setFragmentTexture(material.roughness ?? defaultTexture, index: TextureIndex.roughness.rawValue)
        commandEncoder.setFragmentTexture(material.normal ?? defaultNormalMap, index: TextureIndex.normal.rawValue)
        commandEncoder.setFragmentTexture(material.emissive ?? defaultTexture, index: TextureIndex.emissive.rawValue)
    }
    
    func draw(in view: MTKView) {
        updateScene(view: view)
        
        let commandBuffer = commandQueue.makeCommandBuffer()!
        
        if let renderPassDescriptor = view.currentRenderPassDescriptor {
            let commandEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor)!
            commandEncoder.setRenderPipelineState(renderPipeline)
            commandEncoder.setDepthStencilState(depthStencilState)
            
            commandEncoder.setFragmentTexture(irradianceCubeMap, index: TextureIndex.irradiance.rawValue)
            
            for node in nodes {
                draw(node, in: commandEncoder)
            }
            
            commandEncoder.endEncoding()
            if let drawable = view.currentDrawable {
                commandBuffer.present(drawable)
            }
            commandBuffer.commit()
        }
    }
    
    func draw(_ node: Node, in commandEncoder: MTLRenderCommandEncoder) {
        let mesh = node.mesh
        
        var uniforms = Uniforms(modelMatrix: node.modelMatrix,
                                viewMatrix: viewMatrix,
                                projectionMatrix: projectionMatrix,
                                cameraPosition: cameraWorldPosition,
                                lightDirection: lightWorldDirection,
                                lightPosition: lightWorldPosition)
        commandEncoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: VertexBufferIndex.uniforms.rawValue)
        commandEncoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.size, index: FragmentBufferIndex.uniforms.rawValue)
        
        for (bufferIndex, vertexBuffer) in mesh.vertexBuffers.enumerated() {
            commandEncoder.setVertexBuffer(vertexBuffer.buffer, offset: vertexBuffer.offset, index: bufferIndex)
        }
        
        for (submeshIndex, submesh) in mesh.submeshes.enumerated() {
            let material = node.materials[submeshIndex]
            bindTextures(material, commandEncoder)

            let indexBuffer = submesh.indexBuffer
            commandEncoder.drawIndexedPrimitives(type: submesh.primitiveType,
                                                 indexCount: submesh.indexCount,
                                                 indexType: submesh.indexType,
                                                 indexBuffer: indexBuffer.buffer,
                                                 indexBufferOffset: indexBuffer.offset)
        }
    }
}
