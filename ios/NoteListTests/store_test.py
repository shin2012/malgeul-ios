#!/usr/bin/env python3
"""실제 MeetingStore를 Foundation 런타임에서 실행한다. UI/API 경계만 시험 대역을 쓴다."""
from pathlib import Path
import os
import subprocess
import sys
root=Path(__file__).resolve().parents[1]
out=Path(os.environ['TMPDIR'])/'malgeul-store-check';out.mkdir(parents=True,exist_ok=True)
source=(root/'Malgeul/Core/MeetingStore.swift').read_text().replace('import SwiftUI','')
(out/'MeetingStore.swift').write_text(source)
stubs='''import Foundation
protocol ObservableObject {}
@propertyWrapper struct Published<Value> { var wrappedValue: Value }
extension Error { var isCancellation: Bool { false } }
enum DiskCache {
    static var values: [String: Data] = [:]
    static func save(_ d: Data, key: String) { values[key] = d }
    static func load(key: String) -> Data? { values[key] }
    static func remove(key: String) { values.removeValue(forKey: key) }
}
@MainActor final class API {
    static let shared = API()
    var list = Data("[]".utf8)
    var fail = false
    func meetingsRaw() async throws -> Data {
        if fail { throw NSError(domain: "test", code: 1) }
        return list
    }
    func groups() async throws -> [MeetingGroup] { [] }
    func exchangeRate() async -> Double? { 1300 }
}
@main struct StoreTest {
    @MainActor static func main() async {
        let store=MeetingStore.shared
        store.clear()
        let receipt=Data(#"{"id":701,"title":"시험 녹음","status":"pending","audio_ready":1,"tags":[],"transcript_json":[{"text":"목록 캐시에서 제외"}]}"#.utf8)
        precondition(store.acceptUpload(receipt,displayID:"local-test"))
        precondition(store.meetings.count == 1)
        precondition(!store.acceptUpload(Data("broken".utf8),displayID:"invalid"))
        precondition(store.meetings.count == 1 && !store.displayAliases.values.contains("invalid"))
        print("PASS 잘못된 성공 응답은 저장소를 부분 수정하지 않음")
        precondition(store.displayAliases[701] == "local-test")
        precondition(DiskCache.load(key:"upload_receipt_701") != nil)
        let cached=String(data:DiskCache.load(key:"upload_receipt_701")!,encoding:.utf8)!
        precondition(!cached.contains("transcript_json"))
        print("PASS 업로드 응답을 먼저 반영하고 가벼운 영속 영수증 저장")
        await store.refresh()
        precondition(store.meetings.count == 1)
        print("PASS 목록 응답이 늦어도 새 업로드 행 유지")
        API.shared.fail=true
        await store.refresh()
        precondition(store.meetings.count == 1 && store.lastError != nil)
        print("PASS 목록 네트워크 오류에도 새 업로드 행 유지")
        API.shared.fail=false;API.shared.list=Data("[".utf8)+receipt+Data("]".utf8)
        await store.refresh()
        precondition(store.meetings.count == 1)
        precondition(DiskCache.load(key:"upload_receipt_701") == nil)
        print("PASS 서버 목록에 도착하면 영수증 정리하고 같은 행 유지")
        precondition(store.acceptUpload(receipt,displayID:"local-test"))
        store.remove([701])
        precondition(DiskCache.load(key:"upload_receipt_701") == nil)
        precondition((UserDefaults.standard.stringArray(forKey:"noteUploadReceipts") ?? []).isEmpty)
        print("PASS 바로 삭제한 업로드 영수증은 재실행 때 되살아나지 않음")
        store.clear()
        precondition(store.meetings.isEmpty && store.displayAliases.isEmpty)
        print("PASS 로그아웃 시 업로드·표시 별칭·캐시 정리")
    }
}
'''
(out/'StoreTest.swift').write_text(stubs)
compiler=sys.argv[1]
subprocess.run([compiler,'-parse-as-library',str(root/'Malgeul/Core/Models.swift'),str(out/'MeetingStore.swift'),str(out/'StoreTest.swift'),'-o',str(out/'tests')],check=True)
subprocess.run([str(out/'tests')],check=True)
