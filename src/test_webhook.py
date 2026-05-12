"""
test_webhook.py
Run with:  python test_webhook.py
The server must be running locally on port 8000.
"""

import json
import httpx

BASE_URL = "http://localhost:8000"

TEST_CASES = [
    {
        "label": "Test 1 — WhatsApp availability + pricing (pre-sales)",
        "payload": {
            "source": "whatsapp",
            "guest_name": "Rahul Sharma",
            "message": "Is the villa available from April 20 to 24? What is the rate for 2 adults?",
            "timestamp": "2026-05-05T10:30:00Z",
            "booking_ref": "NIS-2024-0891",
            "property_id": "villa-b1",
        },
    },
    {
        "label": "Test 2 — Booking.com check-in query (post-sales)",
        "payload": {
            "source": "booking_com",
            "guest_name": "Priya Mehta",
            "message": "Hello! What time can we check in? Also can you send the WiFi password and the address?",
            "timestamp": "2026-05-06T08:15:00Z",
            "booking_ref": "BKG-9982211",
            "property_id": "villa-b1",
        },
    },
    {
        "label": "Test 3 — Airbnb complaint (AC not working)",
        "payload": {
            "source": "airbnb",
            "guest_name": "James O'Brien",
            "message": "This is unacceptable. The air conditioning in the master bedroom has not been working since we arrived. It's 35 degrees outside. I want this fixed immediately or I am leaving a 1-star review.",
            "timestamp": "2026-05-07T14:45:00Z",
            "booking_ref": "AIR-77643",
            "property_id": "villa-b1",
        },
    },
    {
        "label": "Test 4 — Direct enquiry special request (chef + early check-in)",
        "payload": {
            "source": "direct",
            "guest_name": "Ananya Krishnan",
            "message": "We are arriving at noon. Can we check in early? Also we would like to arrange a private chef for dinner on our first evening.",
            "timestamp": "2026-05-08T09:00:00Z",
            "booking_ref": "NIS-2025-1104",
            "property_id": "villa-b1",
        },
    },
    {
        "label": "Test 5 — Instagram general enquiry (pets)",
        "payload": {
            "source": "instagram",
            "guest_name": "Siddharth Rao",
            "message": "Hey! Do you guys allow pets? We have a friendly golden retriever.",
            "timestamp": "2026-05-09T11:20:00Z",
            "booking_ref": None,
            "property_id": "villa-b1",
        },
    },
]


def run_tests():
    print("=" * 65)
    print("  Nistula Guest Message Handler — Test Suite")
    print("=" * 65)

    with httpx.Client(timeout=60) as client:
        # Health check first
        try:
            r = client.get(f"{BASE_URL}/health")
            print(f"\n✅  Server health: {r.json()['status'].upper()}\n")
        except Exception as e:
            print(f"\n❌  Server not reachable: {e}")
            print("    Start the server with:  uvicorn main:app --reload\n")
            return

        for tc in TEST_CASES:
            print(f"{'─'*65}")
            print(f"  {tc['label']}")
            print(f"{'─'*65}")

            # Remove None values from payload
            payload = {k: v for k, v in tc["payload"].items() if v is not None}

            try:
                resp = client.post(f"{BASE_URL}/webhook/message", json=payload)
                data = resp.json()

                if resp.status_code == 200:
                    print(f"  message_id      : {data['message_id']}")
                    print(f"  query_type      : {data['query_type']}")
                    print(f"  confidence_score: {data['confidence_score']}")
                    print(f"  action          : {data['action'].upper()}")
                    print(f"\n  drafted_reply:\n")
                    for line in data["drafted_reply"].split("\n"):
                        print(f"    {line}")
                else:
                    print(f"  ❌ HTTP {resp.status_code}: {data.get('detail', data)}")

            except Exception as e:
                print(f"  ❌ Request failed: {e}")

            print()


if __name__ == "__main__":
    run_tests()
