// Copyright (c) 2025-2026 ImmersiveMap contributors.
// SPDX-License-Identifier: MIT

import ImmersiveMapGPU
@testable import ImmersiveMapWebGPU
import Testing

/// A sink that keeps each submission's stream.
private final class StreamSink: WebGPUCommandSink, @unchecked Sendable {
    var streams: [[UInt8]] = []

    func submit(_ stream: UnsafeRawBufferPointer) {
        streams.append(Array(stream))
    }
}

/// One decoded command: its opcode and its arguments as the format gives
/// them.
private struct Command: Equatable {
    enum Argument: Equatable {
        case word(UInt32)
        case float(Float)
        case bytes([UInt8])
        case string(String)
    }

    let opcode: WebGPUOpcode
    let arguments: [Argument]

    func word(_ index: Int) -> UInt32? {
        if case let .word(value) = arguments[index] { return value }
        return nil
    }

    func string(_ index: Int) -> String? {
        if case let .string(value) = arguments[index] { return value }
        return nil
    }
}

/// Reads a stream by the format of `WebGPUCommandStream.swift`, as the
/// host's decoder does.
private struct StreamReader {
    let bytes: [UInt8]
    var position = 0

    mutating func word() throws -> UInt32 {
        guard position + 4 <= bytes.count else { throw ReadError.truncated }
        defer { position += 4 }
        return UInt32(bytes[position]) | UInt32(bytes[position + 1]) << 8
            | UInt32(bytes[position + 2]) << 16 | UInt32(bytes[position + 3]) << 24
    }

    mutating func byteRun() throws -> [UInt8] {
        let length = Int(try word())
        guard position + length <= bytes.count else { throw ReadError.truncated }
        let run = Array(bytes[position ..< position + length])
        position += (length + 3) & ~3
        #expect(bytes[position - ((length + 3) & ~3) + length ..< position].allSatisfy { $0 == 0 }, "Padding is zeros")
        return run
    }

    enum ReadError: Error {
        case truncated
        case unknownOpcode(UInt32)
    }

    enum Kind {
        case word, float, bytes, string
    }

    static func layout(of opcode: WebGPUOpcode) -> [Kind] {
        switch opcode {
        case .createBuffer: return [.word, .word]
        case .writeBuffer: return [.word, .word, .bytes]
        case .createTexture, .createSampler, .createDepthStencilState, .createRenderPipeline: return [.word, .string]
        case .writeTexture: return Array(repeating: .word, count: 8) + [.bytes]
        case .createPipelineVariant: return [.word, .word, .word, .word, .word, .float, .float, .float, .word, .word]
        case .release, .setPipelineVariant, .setStencilReference, .generateMipmaps, .submit: return [.word]
        case .beginRenderPass, .endPass, .popDebugGroup: return []
        case .setViewport: return Array(repeating: .float, count: 6)
        case .setScissorRect: return Array(repeating: .word, count: 4)
        case .setBuffer: return Array(repeating: .word, count: 4)
        case .setBytes: return [.word, .word, .bytes]
        case .setTexture, .setSampler: return Array(repeating: .word, count: 3)
        case .draw: return Array(repeating: .word, count: 4)
        case .drawIndexed: return Array(repeating: .word, count: 7)
        case .pushDebugGroup: return [.string]
        case .copyBufferToBuffer: return Array(repeating: .word, count: 5)
        case .copyBufferToTexture: return Array(repeating: .word, count: 10)
        case .copyTextureToTexture: return Array(repeating: .word, count: 12)
        }
    }

    mutating func commands() throws -> [Command] {
        var commands: [Command] = []
        while position < bytes.count {
            let raw = try word()
            guard let opcode = WebGPUOpcode(rawValue: raw) else { throw ReadError.unknownOpcode(raw) }
            var arguments: [Command.Argument] = []
            if opcode == .beginRenderPass {
                let colors = try word()
                arguments.append(.word(colors))
                for _ in 0 ..< colors {
                    for _ in 0 ..< 4 { arguments.append(.word(try word())) }
                    for _ in 0 ..< 4 { arguments.append(.float(Float(bitPattern: try word()))) }
                }
                let hasDepth = try word()
                arguments.append(.word(hasDepth))
                if hasDepth == 1 {
                    for _ in 0 ..< 3 { arguments.append(.word(try word())) }
                    arguments.append(.float(Float(bitPattern: try word())))
                    arguments.append(.word(try word()))
                }
                arguments.append(.string(String(decoding: try byteRun(), as: UTF8.self)))
            } else {
                for kind in Self.layout(of: opcode) {
                    switch kind {
                    case .word: arguments.append(.word(try word()))
                    case .float: arguments.append(.float(Float(bitPattern: try word())))
                    case .bytes: arguments.append(.bytes(try byteRun()))
                    case .string: arguments.append(.string(String(decoding: try byteRun(), as: UTF8.self)))
                    }
                }
            }
            commands.append(Command(opcode: opcode, arguments: arguments))
        }
        return commands
    }
}

/// The WebGPU backend's stream, read back: what each call of the interface
/// asks of the host, in the order the host must run it.
struct WebGPUDeviceTests {
    private func device() -> (WebGPUDevice, StreamSink) {
        let sink = StreamSink()
        return (WebGPUDevice(features: [], sink: sink), sink)
    }

    private func commit(_ device: WebGPUDevice, sink: StreamSink,
                        encode: (any GPUCommandBuffer) -> Void = { _ in }) throws -> [Command] {
        let buffer = try #require(device.makeCommandQueue()?.makeCommandBuffer())
        encode(buffer)
        buffer.commit()
        var reader = StreamReader(bytes: try #require(sink.streams.last))
        return try reader.commands()
    }

    private func pipeline(_ device: WebGPUDevice) throws -> any GPURenderPipeline {
        var descriptor = GPURenderPipelineDescriptor(vertexFunction: GPUShaderFunction(name: "v", constants: [1: .bool(true)]),
                                                     fragmentFunction: GPUShaderFunction(name: "f"),
                                                     colorTargets: [GPUColorTarget(format: .bgra8Unorm)])
        descriptor.label = "Test"
        descriptor.depthStencilFormat = .depth32FloatStencil8
        return try device.makeRenderPipeline(descriptor)
    }

    @Test func aBufferIsMadeAndWrittenBeforeTheCommandsThatReadIt() throws {
        let (device, sink) = device()
        let bytes: [UInt8] = [1, 2, 3, 4, 5]
        let buffer = try #require(bytes.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: 5, storage: .shared) })
        let commands = try commit(device, sink: sink)
        #expect(commands.map(\.opcode) == [.createBuffer, .writeBuffer, .submit])
        #expect(commands[0].arguments == [.word(WebGPUHandle.first), .word(8)], "Made 4-byte aligned")
        #expect(commands[1].arguments == [.word(WebGPUHandle.first), .word(0), .bytes([1, 2, 3, 4, 5, 0, 0, 0])])
        #expect(buffer.length == 5)
    }

    @Test func writtenBytesUploadOnceAtTheNextCommit() throws {
        let (device, sink) = device()
        let buffer = try #require(device.makeBuffer(length: 4, storage: .shared))
        _ = try commit(device, sink: sink)
        buffer.contents().storeBytes(of: UInt32(0x0403_0201), as: UInt32.self)
        let first = try commit(device, sink: sink)
        #expect(first.map(\.opcode) == [.writeBuffer, .submit])
        #expect(first[0].arguments[2] == .bytes([1, 2, 3, 4]))
        #expect(try commit(device, sink: sink).map(\.opcode) == [.submit], "Nothing written since")
    }

    @Test func anObjectGoneIsReleased() throws {
        let (device, sink) = device()
        var buffer = device.makeBuffer(length: 16, storage: .private)
        _ = try commit(device, sink: sink)
        #expect(buffer != nil)
        buffer = nil
        let commands = try commit(device, sink: sink)
        #expect(commands.first == Command(opcode: .release, arguments: [.word(WebGPUHandle.first)]))
    }

    @Test func descriptorsGoAsJSONInWebGPUsNames() throws {
        let (device, sink) = device()
        let pipeline = try pipeline(device)
        var stencil = GPUStencilFaceState()
        stencil.compare = .equal
        stencil.pass = .replace
        stencil.writeMask = 0x7F
        var depth = GPUDepthStencilDescriptor()
        depth.depthCompare = .lessEqual
        depth.depthWriteEnabled = true
        depth.frontStencil = stencil
        depth.backStencil = stencil
        let depthState = device.makeDepthStencilState(depth)
        var texture = GPUTextureDescriptor(format: .r16Float, width: 256, height: 128)
        texture.mipmapLevelCount = 3
        let made = device.makeTexture(texture)
        let commands = try commit(device, sink: sink)
        withExtendedLifetime((pipeline, depthState, made)) {}
        #expect(commands.map(\.opcode) == [.createRenderPipeline, .createDepthStencilState, .createTexture, .submit])
        #expect(commands[0].string(1) == #"{"label":"Test","vertex":{"entryPoint":"v","constants":{"1":1}},"buffers":[],"fragment":{"entryPoint":"f","constants":{}},"targets":[{"format":"bgra8unorm","writesColor":true}],"depthStencilFormat":"depth32float-stencil8","sampleCount":1,"topology":"triangle-list"}"#)
        let depthJSON = try #require(commands[1].string(1))
        #expect(depthJSON.contains(#""depthCompare":"less-equal","depthWriteEnabled":true"#))
        #expect(depthJSON.contains(#""stencilFront":{"compare":"equal","failOp":"keep","depthFailOp":"keep","passOp":"replace"}"#))
        #expect(depthJSON.contains(#""stencilWriteMask":127"#))
        #expect(commands[2].string(1) == #"{"format":"r16float","width":256,"height":128,"depthOrArrayLayers":1,"viewDimension":"2d","mipLevelCount":3,"sampleCount":1,"shaderRead":true,"renderTarget":false}"#)
    }

    @Test func aDrawBindsTheVariantItsStateNeedsOnce() throws {
        let (device, sink) = device()
        let pipeline = try pipeline(device)
        let depth = try #require(device.makeDepthStencilState(GPUDepthStencilDescriptor()))
        let indices = try #require(device.makeBuffer(length: 64, storage: .private))
        _ = try commit(device, sink: sink)

        let canvas = device.canvasTexture(format: .bgra8Unorm, width: 800, height: 600)
        let commands = try commit(device, sink: sink) { buffer in
            var color = GPUColorAttachment(texture: canvas)
            color.clearColor = GPUClearColor(red: 0, green: 0, blue: 0.5, alpha: 1)
            let encoder = buffer.makeRenderEncoder(GPURenderPassDescriptor(colorAttachments: [color]))!
            encoder.setPipeline(pipeline)
            encoder.setDepthStencilState(depth)
            encoder.setCullMode(.back)
            encoder.setVertexValue(Float(2), index: 7)
            encoder.draw(.triangle, vertexStart: 0, vertexCount: 3)
            encoder.draw(.triangle, vertexStart: 3, vertexCount: 3)
            encoder.drawIndexed(.line, indexCount: 4, indexType: .uint16, indexBuffer: indices, indexBufferOffset: 8)
            encoder.endEncoding()
        }
        #expect(commands.map(\.opcode) == [.createPipelineVariant, .createPipelineVariant,
                                           .beginRenderPass, .setBytes, .setPipelineVariant, .draw, .draw,
                                           .setPipelineVariant, .drawIndexed, .endPass, .submit],
                "The variants are made before the commands that bind them, and bound only where the state changes")
        let triangles = commands[0], lines = commands[1]
        #expect(triangles.arguments[1...4] == [.word(2), .word(3), .word(2), .word(0)],
                "The pipeline, the depth state, back culling, clockwise front faces")
        #expect(triangles.word(9) == 2 && lines.word(9) == 1, "A triangle-list variant, then a line-list one")
        #expect(commands[2].arguments[1] == .word(WebGPUHandle.canvas))
        #expect(commands[2].arguments[7] == .float(0.5))
        #expect(commands[3].arguments == [.word(0), .word(7), .bytes([0, 0, 0, 64])])
        #expect(commands[4].word(0) == triangles.word(0) && commands[7].word(0) == lines.word(0))
        #expect(commands[8].arguments == [.word(0), .word(4), .word(4), .word(8), .word(1), .word(0), .word(0)])
    }

    @Test func theSameStateInAnotherPassReusesItsVariant() throws {
        let (device, sink) = device()
        let pipeline = try pipeline(device)
        let canvas = device.canvasTexture(format: .bgra8Unorm, width: 8, height: 8)
        func frame() throws -> [Command] {
            try commit(device, sink: sink) { buffer in
                let encoder = buffer.makeRenderEncoder(GPURenderPassDescriptor(colorAttachments: [GPUColorAttachment(texture: canvas)]))!
                encoder.setPipeline(pipeline)
                encoder.draw(.triangle, vertexStart: 0, vertexCount: 3)
                encoder.endEncoding()
            }
        }
        #expect(try frame().contains { $0.opcode == .createPipelineVariant })
        let second = try frame()
        #expect(second.contains { $0.opcode == .createPipelineVariant } == false)
        #expect(second.contains { $0.opcode == .setPipelineVariant }, "A new pass binds its variant again")
    }

    @Test func aPipelineGoneTakesItsVariantsWithIt() throws {
        let (device, sink) = device()
        var pipeline: (any GPURenderPipeline)? = try self.pipeline(device)
        let canvas = device.canvasTexture(format: .bgra8Unorm, width: 8, height: 8)
        let drawn = try commit(device, sink: sink) { buffer in
            let encoder = buffer.makeRenderEncoder(GPURenderPassDescriptor(colorAttachments: [GPUColorAttachment(texture: canvas)]))!
            encoder.setPipeline(pipeline!)
            encoder.draw(.triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
        }
        let variant = try #require(drawn.first { $0.opcode == .createPipelineVariant }?.word(0))
        pipeline = nil
        let released = try commit(device, sink: sink).filter { $0.opcode == .release }.compactMap { $0.word(0) }
        #expect(released == [variant, WebGPUHandle.first], "The variant, then the pipeline")
    }

    @Test func theCompletedHandlersRunWhenTheHostSaysSo() throws {
        let (device, sink) = device()
        final class Flag: @unchecked Sendable { var isSet = false }
        let flag = Flag()
        let commands = try commit(device, sink: sink) { buffer in
            buffer.addCompletedHandler { flag.isSet = true }
        }
        let id = try #require(commands.last?.word(0))
        #expect(flag.isSet == false)
        device.commandBufferCompleted(id)
        #expect(flag.isSet)
    }
}
