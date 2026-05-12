# Thinking — Part 3 Written Answers

---

Question A — The Immediate Response
Hi [Guest Name], I'm really sorry — this is not okay and I completely understand your frustration. I've just escalated this to our caretaker right now and someone will be at the villa within the next 30 minutes to fix the hot water. I'll follow up with you directly once it's resolved. We'll also make sure breakfast isn't disrupted. Regarding the refund — I've flagged this for our team and we'll sort it out properly in the morning, not at 3am when you're dealing with this. You have my word.
Why this wording: The guest is stressed and embarrassed in front of arriving guests — they need to feel heard and see action, not policies. Acknowledging the refund without committing to it buys time while still validating them. Mentioning the 30-minute caretaker response is a concrete promise that shifts their focus from anger to waiting.

Question B — The System Design
Beyond sending the message, the platform should:
Immediately create an incident record tagged as complaint + urgent + hot_water, set confidence score to 0 (force escalate), and lock the thread from auto-send
Alert the caretaker via WhatsApp/SMS with the guest name, villa, and issue — not just an app notification they might miss at 3am
Alert the property manager on a separate channel with full context: booking ref, guest name, check-in date, message transcript
Start a 30-minute countdown timer. If no human marks the incident as "acknowledged" within 30 minutes, auto-escalate to the next person in the on-call chain and send the guest a follow-up: "We're still on this — our team is on the way."
Log the timestamp of every action: message received, AI reply sent, caretaker notified, human acknowledged, issue resolved. This creates an audit trail for the refund conversation later.
Flag the reservation for a post-stay review so the refund discussion doesn't get lost.

Question C — The Learning
Third time means it's no longer a guest problem — it's a property problem.
The system should automatically surface a pattern alert to the property manager: "Hot water complaints at Villa B1: 3 incidents in 60 days." That alert should include dates, booking refs, and whether it was flagged as resolved each time.
What I'd build: a recurring issue tracker that sits alongside the messaging layer. Every complaint gets tagged with a category and property. When the same tag hits the same property more than twice in 30 days, it triggers a maintenance task (not just a notification) — assigned to someone, with a due date, and linked back to the complaint thread so it can't be closed without a resolution note.
For hot water specifically, the fix is probably a boiler inspection or replacement — a one-time £200 call. The system's job is to make that obvious to the person who can authorise it, before the fourth guest wakes up at 3am.
The deeper principle: AI handles the guest-facing response well. But the system only earns trust if it also fixes the thing that caused the message in the first place.