"""목록 구성 계약. 실제 배치·터치는 시뮬레이터에서 별도로 검증한다."""
from pathlib import Path
import unittest
ROOT = Path(__file__).resolve().parents[1] / 'Malgeul' / 'Views'

class NoteRowContract(unittest.TestCase):
    def contains(self, source, token):
        self.assertTrue(token in source, f'필수 연결 없음: {token}')

    def test_meetings_and_recordings_share_row_content(self):
        meeting = (ROOT / 'MeetingListView.swift').read_text().split('struct MeetingRow: View {', 1)[1].split('/// 아이콘', 1)[0]
        recording = (ROOT / 'RecordTabView.swift').read_text().split('struct RecordingRow: View {', 1)[1].split('/// 녹음 끝', 1)[0]
        self.contains(meeting, 'NoteRowContent(')
        self.contains(recording, 'NoteRowContent(')

    def test_pending_row_keeps_delete_in_persistent_menu(self):
        source = (ROOT / 'TwoTapDeleteButton.swift').read_text().split('struct PendingRecordingListRow: View {', 1)[1]
        self.assertNotIn('if deletion.isArmed(', source)
        self.contains(source, 'NoteRowMenu')
        self.contains(source, 'TwoTapDeleteButton(')
        menu = (ROOT / 'NoteRowContent.swift').read_text()
        self.contains(menu, '.popover(')
        self.contains(menu, '.presentationCompactAdaptation(.popover)')

    def test_projection_counts_and_single_upload_surface(self):
        source = (ROOT / 'MeetingListView.swift').read_text()
        self.contains(source, 'NoteListProjection.rows(')
        self.contains(source, 'let displayedCount = shown.count')
        self.assertNotIn('Section("업로드")', source)
        self.contains(source, 'Label("파일 업로드"')
        self.contains(source, 'Image(systemName: "plus")')

    def test_duplicate_upload_links_to_existing_server_meeting(self):
        source = (ROOT.parent / 'Core' / 'UploadCenter.swift').read_text()
        self.contains(source, 'resolveDuplicate(')
        self.contains(source, 'acceptUpload(data, displayID:')
        self.contains(source, 'removeIfConfigured: false')

    def test_swipe_delete_stays_in_the_revealed_button(self):
        local = (ROOT / 'TwoTapDeleteButton.swift').read_text()
        server = (ROOT / 'MeetingListView.swift').read_text()
        self.contains(local, 'SwipeDeleteRow(')
        self.contains(server, 'SwipeDeleteRow(')
        swipe = ROOT / 'SwipeDeleteRow.swift'
        self.assertTrue(swipe.exists(), '같은 위치를 유지하는 스와이프 행 필요')
        text = swipe.read_text()
        self.contains(text, 'swipe-delete-button')
        self.contains(text, 'confirmation.tap(target)')
        self.assertTrue('requestDelete(' not in text, '다른 표면으로 확인 버튼 이동 금지')

    def test_recording_sheet_does_not_repeat_past_recordings(self):
        source = (ROOT / 'RecordTabView.swift').read_text().split('struct RecorderPanel:', 1)[0]
        self.assertNotIn('ForEach(recordings.items)', source)

    def test_recording_row_has_no_large_play_circle_or_duplicate_local_label(self):
        source = (ROOT / 'RecordTabView.swift').read_text().split('struct RecordingRow: View {', 1)[1].split('/// 녹음 끝', 1)[0]
        self.assertNotIn('play.circle.fill', source)
        self.assertNotIn('기기에만 있음', source)
        self.contains(source, 'NoteRowMetadata(')

if __name__ == '__main__': unittest.main()
