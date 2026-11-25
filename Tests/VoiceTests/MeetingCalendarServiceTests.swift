import Testing
@testable import Voice

@Suite("Calendar call links")
@MainActor
struct MeetingCalendarServiceTests {
    @Test func recognisesSupportedMeetingLinks() {
        #expect(MeetingCalendarService.isVideoCall("Join https://meet.google.com/abc-defg-hij"))
        #expect(MeetingCalendarService.isVideoCall("https://company.zoom.us/j/12345"))
        #expect(MeetingCalendarService.isVideoCall("https://teams.microsoft.com/l/meetup-join/abc"))
    }

    @Test func rejectsLookalikesAndPlainText() {
        #expect(!MeetingCalendarService.isVideoCall("Zoom meeting at 3"))
        #expect(!MeetingCalendarService.isVideoCall("https://zoom.us.example.com/j/123"))
        #expect(!MeetingCalendarService.isVideoCall("http://zoom.us/j/123"))
        #expect(!MeetingCalendarService.isVideoCall("https://example.com/meeting"))
    }
}
