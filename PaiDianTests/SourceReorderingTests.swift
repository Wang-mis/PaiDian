import XCTest
import UIKit
@testable import PaiDian

@MainActor final class SourceReorderingTests:XCTestCase {
    private let scripts=(0..<5).map { SourceScript(name:"测试音源 \($0)",version:"1.0",fileKey:"unused",digest:"\($0)") }
    func testNativeMovementToFirstKeepsOrderUntilSnapshot() async throws {
        let gate=NativeOrderSaveGate(),controller=SourceListController(input:SourceListInput(scripts:scripts),action:{ _ in },save:{ await gate.save($0) })
        let window=show(controller);defer { window.isHidden=true;window.rootViewController=nil }
        try await Task.sleep(for:.milliseconds(200));controller.collectionView.layoutIfNeeded()
        let start=try frame(controller,index:4),first=try frame(controller,index:0)
        XCTAssertTrue(controller.beginReordering(at:CGPoint(x:start.minX+24,y:start.midY)))
        controller.updateReordering(at:CGPoint(x:first.midX,y:first.minY-40))
        try await Task.sleep(for:.milliseconds(250));controller.endReordering(cancelled:false)
        try await wait { gate.orders.count == 1 }
        let expected=[scripts[4].id]+scripts.prefix(4).map(\.id)
        XCTAssertEqual(gate.orders,[expected],"原生交互移动必须真正把末项移到第一位")
        gate.finish(true);try await wait { !controller.isSaving }
        controller.update(input:SourceListInput(scripts:scripts),action:{ _ in },save:{ await gate.save($0) })
        try await Task.sleep(for:.milliseconds(1100))
        XCTAssertEqual(controller.displayedOrder,expected,"旧快照不能把已保存顺序拉回")
        let reordered=expected.map { id in scripts.first { $0.id == id }! }
        controller.update(input:SourceListInput(scripts:reordered),action:{ _ in },save:{ await gate.save($0) })
        XCTAssertEqual(controller.displayedOrder,expected)
        attach(controller.view,name:"native-source-first")
    }
    func testNativeMovementToLastAndCancellation() async throws {
        let gate=NativeOrderSaveGate(),controller=SourceListController(input:SourceListInput(scripts:scripts),action:{ _ in },save:{ await gate.save($0) })
        let window=show(controller);defer { window.isHidden=true;window.rootViewController=nil }
        try await Task.sleep(for:.milliseconds(200));controller.collectionView.layoutIfNeeded()
        let first=try frame(controller,index:0),last=try frame(controller,index:4)
        XCTAssertTrue(controller.beginReordering(at:CGPoint(x:first.minX+24,y:first.midY)))
        controller.updateReordering(at:CGPoint(x:last.midX,y:last.maxY+40))
        try await Task.sleep(for:.milliseconds(250));controller.endReordering(cancelled:true)
        XCTAssertEqual(controller.displayedOrder,scripts.map(\.id));XCTAssertTrue(gate.orders.isEmpty,"取消不能保存")
        try await Task.sleep(for:.milliseconds(200));controller.collectionView.layoutIfNeeded()
        XCTAssertTrue(controller.beginReordering(at:CGPoint(x:first.minX+24,y:first.midY)))
        controller.updateReordering(at:CGPoint(x:last.midX,y:last.maxY+40))
        try await Task.sleep(for:.milliseconds(250));controller.endReordering(cancelled:false)
        try await wait { gate.orders.count == 1 }
        XCTAssertEqual(gate.orders[0],Array(scripts.dropFirst().map(\.id))+[scripts[0].id],"原生交互必须可移动到最后")
        gate.finish(false);try await wait { !controller.isSaving }
        XCTAssertEqual(controller.displayedOrder,scripts.map(\.id),"保存失败才恢复原顺序")
    }
    func testNativeHandleBoundsAndSnapshotBeforeSaveReturn() async throws {
        let gate=NativeOrderSaveGate(),controller=SourceListController(input:SourceListInput(scripts:scripts),action:{ _ in },save:{ await gate.save($0) })
        let window=show(controller);defer { window.isHidden=true;window.rootViewController=nil }
        try await Task.sleep(for:.milliseconds(200));controller.collectionView.layoutIfNeeded()
        let second=try frame(controller,index:1),first=try frame(controller,index:0)
        XCTAssertFalse(controller.beginReordering(at:CGPoint(x:second.maxX-24,y:second.midY)),"右侧菜单不应启动重排")
        XCTAssertTrue(controller.beginReordering(at:CGPoint(x:second.minX+24,y:second.midY)))
        controller.updateReordering(at:CGPoint(x:first.midX,y:first.minY-80))
        try await Task.sleep(for:.milliseconds(250));controller.endReordering(cancelled:false)
        try await wait { gate.orders.count == 1 }
        let expected=[scripts[1],scripts[0]]+Array(scripts.dropFirst(2))
        controller.update(input:SourceListInput(scripts:expected,busy:true),action:{ _ in },save:{ await gate.save($0) })
        gate.finish(true);try await wait { !controller.isSaving }
        controller.update(input:SourceListInput(scripts:expected),action:{ _ in },save:{ await gate.save($0) })
        XCTAssertEqual(controller.displayedOrder,expected.map(\.id));XCTAssertEqual(gate.orders.count,1)
    }
    func testHoldingAboveFirstDoesNotRepeatReordering() async throws {
        let gate=NativeOrderSaveGate(),controller=SourceListController(input:SourceListInput(scripts:scripts),action:{ _ in },save:{ await gate.save($0) })
        let window=show(controller);defer { window.isHidden=true;window.rootViewController=nil }
        try await Task.sleep(for:.milliseconds(200));controller.collectionView.layoutIfNeeded()
        let start=try frame(controller,index:4),first=try frame(controller,index:0)
        XCTAssertTrue(controller.beginReordering(at:CGPoint(x:start.minX+24,y:start.midY)))
        let held=CGPoint(x:first.midX,y:first.minY-35)
        controller.updateReordering(at:held);try await Task.sleep(for:.milliseconds(300))
        let position=try XCTUnwrap(controller.lastMovementPosition),updates=controller.movementPositionUpdateCount,changes=controller.movementTargetChangeCount
        for index in 0..<100 {
            controller.updateReordering(at:CGPoint(x:held.x,y:held.y+CGFloat(index%5-2)))
            try await Task.sleep(for:.milliseconds(16))
        }
        XCTAssertEqual(controller.lastMovementPosition?.y ?? 0,position.y,accuracy:0.5,"首位上方保持手指不动时，目标不能跟随浮动行漂移")
        XCTAssertEqual(controller.movementTargetChangeCount,changes,"保持在首位区域时不能反复更换插入位置")
        XCTAssertLessThanOrEqual(controller.movementPositionUpdateCount-updates,1,"相同边界位置不应重复驱动原生重排和反馈")
        controller.endReordering(cancelled:false);try await wait { gate.orders.count == 1 }
        XCTAssertEqual(gate.orders[0],[scripts[4].id]+scripts.prefix(4).map(\.id));gate.finish(true)
    }
    func testHoldingBelowLastDoesNotRepeatReordering() async throws {
        let gate=NativeOrderSaveGate(),controller=SourceListController(input:SourceListInput(scripts:scripts),action:{ _ in },save:{ await gate.save($0) })
        let window=show(controller);defer { window.isHidden=true;window.rootViewController=nil }
        try await Task.sleep(for:.milliseconds(200));controller.collectionView.layoutIfNeeded()
        let first=try frame(controller,index:0),last=try frame(controller,index:4)
        XCTAssertTrue(controller.beginReordering(at:CGPoint(x:first.minX+24,y:first.midY)))
        let held=CGPoint(x:last.midX,y:last.maxY+35)
        controller.updateReordering(at:held);try await Task.sleep(for:.milliseconds(300))
        let position=try XCTUnwrap(controller.lastMovementPosition),updates=controller.movementPositionUpdateCount,changes=controller.movementTargetChangeCount
        for index in 0..<100 {
            controller.updateReordering(at:CGPoint(x:held.x,y:held.y+CGFloat(index%5-2)))
            try await Task.sleep(for:.milliseconds(16))
        }
        XCTAssertEqual(controller.lastMovementPosition?.y ?? 0,position.y,accuracy:0.5)
        XCTAssertEqual(controller.movementTargetChangeCount,changes,"末位停留不能反复换位")
        XCTAssertLessThanOrEqual(controller.movementPositionUpdateCount-updates,1)
        controller.endReordering(cancelled:false);try await wait { gate.orders.count == 1 }
        XCTAssertEqual(gate.orders[0],Array(scripts.dropFirst().map(\.id))+[scripts[0].id]);gate.finish(true)
    }
    func testBoundaryHysteresisAndReversingDirection() async throws {
        let gate=NativeOrderSaveGate(),controller=SourceListController(input:SourceListInput(scripts:scripts),action:{ _ in },save:{ await gate.save($0) })
        let window=show(controller);defer { window.isHidden=true;window.rootViewController=nil }
        try await Task.sleep(for:.milliseconds(200));controller.collectionView.layoutIfNeeded()
        let first=try frame(controller,index:0),last=try frame(controller,index:4),middle=try frame(controller,index:2)
        XCTAssertTrue(controller.beginReordering(at:CGPoint(x:middle.minX+24,y:middle.midY)))
        controller.updateReordering(at:CGPoint(x:first.midX,y:first.minY-30))
        try await Task.sleep(for:.milliseconds(250))
        let updates=controller.movementPositionUpdateCount,changes=controller.movementTargetChangeCount
        for index in 0..<20 {
            controller.updateReordering(at:CGPoint(x:first.midX,y:first.midY+CGFloat(index%5-2)))
            try await Task.sleep(for:.milliseconds(16))
        }
        XCTAssertEqual(controller.movementTargetChangeCount,changes,"边界轻微来回移动不应释放首位锁定")
        XCTAssertEqual(controller.movementPositionUpdateCount,updates)
        controller.updateReordering(at:CGPoint(x:last.midX,y:last.maxY+30))
        try await Task.sleep(for:.milliseconds(250))
        controller.updateReordering(at:CGPoint(x:middle.midX,y:middle.midY))
        try await Task.sleep(for:.milliseconds(250));controller.endReordering(cancelled:false)
        try await Task.sleep(for:.milliseconds(100))
        XCTAssertEqual(controller.displayedOrder,scripts.map(\.id),"移出边界后应允许返回原位")
        XCTAssertTrue(gate.orders.isEmpty,"返回原位无需保存")
    }
    private func show(_ controller:SourceListController)->UIWindow {
        let window=UIWindow(frame:CGRect(x:0,y:0,width:393,height:852));window.rootViewController=controller;window.makeKeyAndVisible()
        controller.view.frame=window.bounds;controller.view.layoutIfNeeded();return window
    }
    private func frame(_ controller:SourceListController,index:Int) throws -> CGRect {
        try XCTUnwrap(controller.collectionView.layoutAttributesForItem(at:IndexPath(item:index,section:1))).frame
    }
    private func wait(_ condition:()->Bool) async throws {
        for _ in 0..<150 { if condition() { return };try await Task.sleep(for:.milliseconds(10)) }
        throw ValidationFailure(message:"未收到原生重排完成或保存回调")
    }
    private func attach(_ view:UIView,name:String) {
        let renderer=UIGraphicsImageRenderer(bounds:view.bounds)
        let attachment=XCTAttachment(image:renderer.image { _ in view.drawHierarchy(in:view.bounds,afterScreenUpdates:true) });attachment.name=name;attachment.lifetime = .keepAlways;add(attachment)
    }
}
@MainActor private final class NativeOrderSaveGate {
    var orders:[[UUID]]=[]
    private var continuation:CheckedContinuation<Bool,Never>?
    func save(_ order:[UUID]) async -> Bool { orders.append(order);return await withCheckedContinuation { continuation=$0 } }
    func finish(_ success:Bool) { continuation?.resume(returning:success);continuation=nil }
}
