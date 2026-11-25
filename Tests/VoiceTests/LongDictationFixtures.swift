import XCTest
@testable import Voice

// Invented unbroken prose for paragraph layout tests.
enum LongDictationFixtures {
    static let prose: [String] = [
        #"""
The observatory opens at dusk. A small sign near the entrance lists the hours for the coming week. On opening day a volunteer will guide visitors through the building and explain where to leave their coats. The first group can take a seat by the windows while the entrance clears. Visitors can borrow binoculars. The organizers plan to keep extra supplies in a wooden cabinet beside the stairs. Every item has a paper label with a number in the corner. Nobody needs a ticket to look around the main room or ask a volunteer for directions. A volunteer explains the lunar calendar. Afterward there is time to walk through the courtyard and read the notices pinned to the gate. The last group will leave a few minutes before closing so the staff can collect the signs and lock the doors.
"""#,
        #"""
The seed library has three shelves. A small sign near the entrance lists the hours for the coming week. On opening day a volunteer will guide visitors through the building and explain where to leave their coats. The first group can take a seat by the windows while the entrance clears. Paper envelopes protect the beans. The organizers plan to keep extra supplies in a wooden cabinet beside the stairs. Every item has a paper label with a number in the corner. Nobody needs a ticket to look around the main room or ask a volunteer for directions. Families exchange planting notes. Afterward there is time to walk through the courtyard and read the notices pinned to the gate. The last group will leave a few minutes before closing so the staff can collect the signs and lock the doors.
"""#,
        #"""
The museum entrance faces the pond. A small sign near the entrance lists the hours for the coming week. On opening day a volunteer will guide visitors through the building and explain where to leave their coats. The first group can take a seat by the windows while the entrance clears. A ceramic fox marks the path. The organizers plan to keep extra supplies in a wooden cabinet beside the stairs. Every item has a paper label with a number in the corner. Nobody needs a ticket to look around the main room or ask a volunteer for directions. A temporary exhibit covers printmaking. Afterward there is time to walk through the courtyard and read the notices pinned to the gate. The last group will leave a few minutes before closing so the staff can collect the signs and lock the doors.
"""#,
        #"""
A brass bell hangs beside the ferry ramp. A small sign near the entrance lists the hours for the coming week. On opening day a volunteer will guide visitors through the building and explain where to leave their coats. The first group can take a seat by the windows while the entrance clears. Cyclists wait behind the yellow stripe. The organizers plan to keep extra supplies in a wooden cabinet beside the stairs. Every item has a paper label with a number in the corner. Nobody needs a ticket to look around the main room or ask a volunteer for directions. A second boat leaves after sunset. Afterward there is time to walk through the courtyard and read the notices pinned to the gate. The last group will leave a few minutes before closing so the staff can collect the signs and lock the doors.
"""#,
    ]
}
