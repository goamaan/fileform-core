// SPDX-License-Identifier: Apache-2.0
import Foundation
import CoreGraphics
import ImageIO
let bytes: [UInt8] = [255,0,0, 0,255,0, 0,0,255, 255,255,255]
let image = CGImage(width:2,height:2,bitsPerComponent:8,bitsPerPixel:24,bytesPerRow:6,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGBitmapInfo(rawValue:0),provider:CGDataProvider(data:Data(bytes) as CFData)!,decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath:CommandLine.arguments[1]) as CFURL,"public.jpeg" as CFString,1,nil)!
CGImageDestinationAddImage(dst,image,[kCGImageDestinationLossyCompressionQuality:1] as CFDictionary)
assert(CGImageDestinationFinalize(dst))
