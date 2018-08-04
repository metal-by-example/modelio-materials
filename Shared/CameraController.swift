
import QuartzCore
import simd

class CameraController {
    var viewMatrix: float4x4 {
        return float4x4(translationBy: float3(0, 0, -radius)) *
               float4x4(rotationAbout: float3(1, 0, 0), by: altitude) *
               float4x4(rotationAbout: float3(0, 1, 0), by: azimuth)
        
    }
    
    var radius: Float = 3
    var sensitivity: Float = 0.01
    let minAltitude: Float = -.pi / 4
    let maxAltitude: Float = .pi / 2
    
    
    private var altitude: Float = 0
    private var azimuth: Float = 0

    private var lastPoint: CGPoint = .zero
    
    func startedInteraction(at point: CGPoint) {
        lastPoint = point
    }
    
    func dragged(to point: CGPoint) {
        let deltaX = Float(lastPoint.x - point.x)
        let deltaY = Float(lastPoint.y - point.y)
        azimuth += -deltaX * sensitivity
        altitude += -deltaY * sensitivity
        altitude = min(max(minAltitude, altitude), maxAltitude)
        lastPoint = point
    }
}
