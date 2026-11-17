// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU

// The descriptors made once, as the JSON strings the stream carries, in
// WebGPU's names. Written by hand: the target imports no Foundation, which
// adds tens of megabytes to a WebAssembly binary.

/// A JSON value built in code and written out.
enum WebGPUJSON {
    case string(String)
    case number(Double)
    case bool(Bool)
    case null
    case array([WebGPUJSON])
    /// Keys in order, written as given.
    case object([(String, WebGPUJSON)])

    var text: String {
        var out = ""
        write(into: &out)
        return out
    }

    private func write(into out: inout String) {
        switch self {
        case let .string(value):
            out += "\""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\n": out += "\\n"
                default:
                    if scalar.value < 0x20 {
                        let hex = String(scalar.value, radix: 16)
                        out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                    } else {
                        out.unicodeScalars.append(scalar)
                    }
                }
            }
            out += "\""
        case let .number(value):
            if value.isFinite, value == value.rounded(), abs(value) < 1e15 {
                out += String(Int64(value))
            } else if value.isFinite {
                out += String(value)
            } else {
                out += "null"
            }
        case let .bool(value):
            out += value ? "true" : "false"
        case .null:
            out += "null"
        case let .array(values):
            out += "["
            for (index, value) in values.enumerated() {
                if index > 0 { out += "," }
                value.write(into: &out)
            }
            out += "]"
        case let .object(members):
            out += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { out += "," }
                WebGPUJSON.string(member.0).write(into: &out)
                out += ":"
                member.1.write(into: &out)
            }
            out += "}"
        }
    }
}

extension GPUTextureDescriptor {
    /// The label goes along only where there is one, so a texture without
    /// one writes the stream it always wrote.
    var webGPUJSON: WebGPUJSON {
        let dimension: String
        switch type {
        case .type2D, .type2DMultisample: dimension = "2d"
        case .type2DArray: dimension = "2d-array"
        }
        var fields: [(String, WebGPUJSON)] = [
            ("format", .string(format.webGPU)),
            ("width", .number(Double(width))),
            ("height", .number(Double(height))),
            ("depthOrArrayLayers", .number(Double(arrayLength))),
            ("viewDimension", .string(dimension)),
            ("mipLevelCount", .number(Double(mipmapLevelCount))),
            ("sampleCount", .number(Double(sampleCount))),
            ("shaderRead", .bool(usage.contains(.shaderRead))),
            ("renderTarget", .bool(usage.contains(.renderTarget))),
        ]
        if let label {
            fields.append(("label", .string(label)))
        }
        return .object(fields)
    }
}

extension GPUAddressMode {
    var webGPU: String { self == .clampToEdge ? "clamp-to-edge" : "repeat" }
}

extension GPUFilter {
    var webGPU: String { self == .nearest ? "nearest" : "linear" }
}

extension GPUSamplerDescriptor {
    var webGPUJSON: WebGPUJSON {
        .object([
            ("addressModeU", .string(addressModeU.webGPU)),
            ("addressModeV", .string(addressModeV.webGPU)),
            ("magFilter", .string(magFilter.webGPU)),
            ("minFilter", .string(minFilter.webGPU)),
            ("mipmapFilter", .string(mipFilter.webGPU)),
            ("maxAnisotropy", .number(Double(maxAnisotropy))),
        ])
    }
}

extension GPUStencilOperation {
    var webGPU: String {
        switch self {
        case .keep: return "keep"
        case .zero: return "zero"
        case .replace: return "replace"
        case .incrementClamp: return "increment-clamp"
        case .decrementClamp: return "decrement-clamp"
        case .invert: return "invert"
        case .incrementWrap: return "increment-wrap"
        case .decrementWrap: return "decrement-wrap"
        }
    }
}

extension GPUStencilFaceState {
    var webGPUJSON: WebGPUJSON {
        .object([
            ("compare", .string(compare.webGPU)),
            ("failOp", .string(stencilFailure.webGPU)),
            ("depthFailOp", .string(depthFailure.webGPU)),
            ("passOp", .string(pass.webGPU)),
        ])
    }
}

extension GPUDepthStencilDescriptor {
    /// WebGPU has one read and one write mask for both faces: the front's,
    /// which is what the engine sets for both. A face without a stencil
    /// state keeps the stencil, as Metal's nil does.
    var webGPUJSON: WebGPUJSON {
        let keep = GPUStencilFaceState()
        let masks = frontStencil ?? backStencil ?? keep
        return .object([
            ("depthCompare", .string(depthCompare.webGPU)),
            ("depthWriteEnabled", .bool(depthWriteEnabled)),
            ("stencilFront", (frontStencil ?? keep).webGPUJSON),
            ("stencilBack", (backStencil ?? keep).webGPUJSON),
            ("stencilReadMask", .number(Double(masks.readMask))),
            ("stencilWriteMask", .number(Double(masks.writeMask))),
            ("usesStencil", .bool(frontStencil != nil || backStencil != nil)),
        ])
    }
}

extension GPURenderPipelineDescriptor {
    /// The manifest's shape (`Tools/WGSLCheck/pipelines.json`), which the
    /// WGSL check already builds with Dawn.
    var webGPUJSON: WebGPUJSON {
        func stage(_ function: GPUShaderFunction) -> WebGPUJSON {
            .object([
                ("entryPoint", .string(function.name)),
                ("constants", .object(function.constants.sorted { $0.key < $1.key }.map { (String($0.key), .number($0.value.webGPU)) })),
            ])
        }
        let buffers: [WebGPUJSON] = (vertexLayout?.webGPUBuffers ?? []).map { buffer in
            guard let buffer else { return .null }
            return .object([
                ("arrayStride", .number(Double(buffer.arrayStride))),
                ("attributes", .array(buffer.attributes.map { attribute in
                    .object([
                        ("format", .string(attribute.format)),
                        ("offset", .number(Double(attribute.offset))),
                        ("shaderLocation", .number(Double(attribute.shaderLocation))),
                    ])
                })),
            ])
        }
        let targets: [WebGPUJSON] = colorTargets.map { target in
            var members: [(String, WebGPUJSON)] = [("format", .string(target.format.webGPU))]
            if let blend = target.blend {
                func component(_ component: GPUBlendComponent) -> WebGPUJSON {
                    .object([
                        ("srcFactor", .string(component.source.webGPU)),
                        ("dstFactor", .string(component.destination.webGPU)),
                        ("operation", .string(component.operation.webGPU)),
                    ])
                }
                members.append(("blend", .object([("color", component(blend.color)), ("alpha", component(blend.alpha))])))
            }
            members.append(("writesColor", .bool(target.writesColor)))
            return .object(members)
        }
        return .object([
            ("label", .string(label ?? vertexFunction.name)),
            ("vertex", stage(vertexFunction)),
            ("buffers", .array(buffers)),
            ("fragment", fragmentFunction.map(stage) ?? .null),
            ("targets", .array(targets)),
            ("depthStencilFormat", depthStencilFormat.map { .string($0.webGPU) } ?? .null),
            ("sampleCount", .number(Double(sampleCount))),
            ("topology", .string(topology.webGPU)),
        ])
    }
}
