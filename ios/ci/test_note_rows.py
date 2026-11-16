"""목록의 공통 행 구성 계약. 실제 배치는 iPhone/iPad 시뮬레이터 캡처로 별도 확인한다."""
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1] / 'Malgeul' / 'Views'

class NoteRowContract(unittest.TestCase):
    def test_meetings_and_recordings_share_row_content(self):
        meeting = (ROOT / 'MeetingListView.swift').read_text().split('struct MeetingRow: View {', 1)[1].split('/// 아이콘', 1)[0]
        recording = (ROOT / 'RecordTabView.swift').read_text().split('struct RecordingRow: View {', 1)[1].split('/// 녹음 끝', 1)[0]
        self.assertIn('NoteRowContent(', meeting)
        self.assertIn('NoteRowContent(', recording)

    def test_pending_row_has_no_repeated_status_or_permanent_action_bar(self):
        source = (ROOT / 'TwoTapDeleteButton.swift').read_text().split('struct PendingRecordingListRow: View {', 1)[1]
        self.assertNotIn('받아쓰기 전 · 기기에 보관됨', source)
        self.assertNotIn('Button("업로드")', source)
        self.assertIn('if deletion.isArmed(', source)
        self.assertIn('NoteRowMenu', source)

    def test_recording_row_has_no_large_play_circle_or_duplicate_local_label(self):
        source = (ROOT / 'RecordTabView.swift').read_text().split('struct RecordingRow: View {', 1)[1].split('/// 녹음 끝', 1)[0]
        self.assertNotIn('play.circle.fill', source)
        self.assertNotIn('기기에만 있음', source)
        self.assertIn('NoteRowMetadata(', source)

if __name__ == '__main__': unittest.main()
