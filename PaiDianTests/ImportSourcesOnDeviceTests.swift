import XCTest
import UIKit
@testable import PaiDian

// Explicit, user-authorized device setup. Never runs in the ordinary test scheme.
@MainActor final class ImportSourcesOnDeviceTests:XCTestCase {
    struct Input:Decodable { let key:String;let url:URL }
    func testImportAuthorizedSourceList() async throws {
        guard ProcessInfo.processInfo.environment["PAIDIAN_IMPORT_SOURCES"] == "1" else { throw XCTSkip("仅用于明确授权的音源导入") }
        let wasDisabled=UIApplication.shared.isIdleTimerDisabled;UIApplication.shared.isIdleTimerDisabled=true
        defer { UIApplication.shared.isIdleTimerDisabled=wasDisabled }
        let folder=URL.cachesDirectory.appendingPathComponent("SourceValidation")
        let inputs=try JSONDecoder().decode([Input].self,from:Data(contentsOf:folder.appendingPathComponent("imports.json")))
        let store=MusicStore(modelContainer:try MusicStore.container());try await store.prepare()
        let original=try await store.activeScriptID()
        let files=try DiskFileStore(root:URL.applicationSupportDirectory.appendingPathComponent("AnyListen"))
        let manager=SourceManager(repository:store,files:files,http:URLSessionHTTPClient())
        var imported:[(String,SourceScript)]=[]
        for input in inputs {
            XCTAssertTrue(input.key.range(of:#"^[a-z]+$"#,options:.regularExpression) != nil)
            let url=folder.appendingPathComponent(input.key+".js"),data=try Data(contentsOf:url)
            let existing=try await store.scripts()
            var script:SourceScript
            if let prior=existing.first(where:{$0.digest == DataDigest.sha256(data)}) { script=prior }
            else { script=try await manager.importScript(SourceImport(url:url,retainOnInitializationFailure:true)) }
            script.originURL=input.url;try await store.save(script)
            imported.append((input.key,script))
        }
        await manager.restoreActive()
        if original == nil,let star=imported.first(where:{$0.0 == "xinghai"}) { try await manager.activate(scriptID:star.1.id) }
        let active=try await store.activeScriptID()
        let ordered=imported.sorted { ($0.0 == "qdy" ? 0 : 1) < ($1.0 == "qdy" ? 0 : 1) }.filter{$0.1.id != active && $0.1.initializationError == nil}
        let priority=([active].compactMap{$0}+ordered.map{$0.1.id})
        let others=try await store.scripts().map(\.id).filter{!priority.contains($0)}
        try await manager.setSourceOrder(scriptIDs:priority+others)
        let saved=try await store.scripts();XCTAssertEqual(Set(imported.map{$0.1.digest}).count,11)
        XCTAssertTrue(imported.allSatisfy{item in saved.contains{$0.id == item.1.id}})
        if let original { XCTAssertEqual(active,original,"不得更换用户主音源") }
        let report=imported.map { key,script in "\(key)：\(script.name)；\(script.initializationError == nil ? "已初始化" : "初始化失败："+script.initializationError!)；\(script.digest)" }.joined(separator:"\n")
        let attachment=XCTAttachment(string:report);attachment.name="authorized-source-import";attachment.lifetime = .keepAlways;add(attachment)
    }
}
