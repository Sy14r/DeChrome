import AppKit
import Foundation

let output = URL(fileURLWithPath:CommandLine.arguments[1], isDirectory:true)
try FileManager.default.createDirectory(at:output, withIntermediateDirectories:true)
var entries = Data()
func appendWord(_ value:UInt32, to data:inout Data) {
    var bigEndian=value.bigEndian
    withUnsafeBytes(of:&bigEndian) { data.append(contentsOf:$0) }
}
let iconTypes=[16:"icp4",32:"icp5",64:"icp6",128:"ic07",256:"ic08",512:"ic09",1024:"ic10"]
for size in [16,32,64,128,256,512,1024] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
    let context = NSGraphicsContext(bitmapImageRep:bitmap)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x:CGFloat(size)/1024,y:CGFloat(size)/1024)
    NSColor(calibratedRed:0.065,green:0.13,blue:0.165,alpha:1).setFill()
    NSBezierPath(roundedRect:NSRect(x:64,y:64,width:896,height:896),xRadius:200,yRadius:200).fill()
    let window = NSBezierPath(roundedRect:NSRect(x:225,y:282,width:574,height:460),xRadius:65,yRadius:65)
    window.lineWidth = 25
    NSColor(calibratedRed:0.435,green:0.886,blue:0.753,alpha:1).setStroke()
    window.stroke()
    let arrow = NSBezierPath()
    arrow.move(to:NSPoint(x:420,y:410)); arrow.line(to:NSPoint(x:588,y:578))
    arrow.move(to:NSPoint(x:444,y:578)); arrow.line(to:NSPoint(x:588,y:578)); arrow.line(to:NSPoint(x:588,y:434))
    arrow.lineWidth=28; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round
    NSColor(calibratedWhite:0.95,alpha:1).setStroke(); arrow.stroke()
    NSGraphicsContext.restoreGraphicsState()
    let data = bitmap.representation(using:.png,properties:[:])!
    entries.append(Data(iconTypes[size]!.utf8))
    appendWord(UInt32(data.count+8),to:&entries)
    entries.append(data)
    if [16,32,128,256,512].contains(size) { try data.write(to:output.appendingPathComponent("icon_\(size)x\(size).png")) }
    if [32,64,256,512,1024].contains(size) { try data.write(to:output.appendingPathComponent("icon_\(size/2)x\(size/2)@2x.png")) }
}
var icon=Data("icns".utf8)
appendWord(UInt32(entries.count+8),to:&icon)
icon.append(entries)
let iconURL=output.deletingLastPathComponent().appendingPathComponent("AppIcon.icns")
try icon.write(to:iconURL)
guard NSImage(contentsOf:iconURL)?.isValid == true else { fatalError("Generated app icon is unreadable") }
