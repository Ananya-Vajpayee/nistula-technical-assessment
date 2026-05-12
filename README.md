# Nistula Technical Assessment

Submitted by: Ananya Vajpayee

This repository contains all three parts of the Nistula backend technical assessment.

```
nistula-technical-assessment/
├── src/                   ← Part 1: FastAPI webhook application
│   ├── main.py
│   └── test_webhook.py
├── schema.sql             ← Part 2: PostgreSQL schema
├── thinking.md            ← Part 3: Written answers
├── requirements.txt
├── .env.example
└── README.md              ← You are here
```

---

## Part 1 — Guest Message Handler

### Setup

```bash
# 1. Create and activate a virtual environment
python -m venv .venv
source .venv/bin/activate        # Windows: .venv\Scripts\activate

# 2. Install dependencies
pip install -r requirements.txt

# 3. Configure environment
cp .env.example .env
# Open .env and set ANTHROPIC_API_KEY=sk-ant-...

# 4. Start the server
uvicorn src.main:app --reload

# 5. Run the test suite (in a second terminal)
python src/test_webhook.py
```

Interactive API docs: `http://localhost:8000/docs`

---

### How it works

`POST /webhook/message` runs a four-step pipeline:

```
Inbound payload
      │
      ▼
 Validate source field (whatsapp / booking_com / airbnb / instagram / direct)
      │
      ▼
 Claude call #1 — classify query into one of 6 types (max_tokens: 20)
      │
      ▼
 Normalise into unified schema + generate UUID
      │
      ▼
 Claude call #2 — draft reply with property context + channel tone hint
      │
      ▼
 Score confidence → assign action → return JSON
```

### Query types

| Type | Meaning |
|---|---|
| `pre_sales_availability` | Dates / availability before booking |
| `pre_sales_pricing` | Rates and costs before booking |
| `post_sales_checkin` | Check-in time, WiFi, directions after booking |
| `special_request` | Chef, early check-in, airport transfer |
| `complaint` | Active problem or dissatisfaction |
| `general_enquiry` | Everything else |

---

### Confidence scoring logic

The score is a float between 0 and 1, derived from three signals:

**1. Base — Claude's `stop_reason`**

| Value | Base score | Rationale |
|---|---|---|
| `end_turn` | 0.90 | Reply completed naturally — trustworthy |
| `max_tokens` | 0.55 | Reply was cut off — may be incomplete |

**2. Query-type adjustment**

| Query type | Δ | Rationale |
|---|---|---|
| `pre_sales_availability` | +0.05 | Full property context available |
| `pre_sales_pricing` | +0.04 | Rate table fully specified |
| `post_sales_checkin` | +0.03 | House info fully known |
| `general_enquiry` | ±0.00 | Neutral |
| `special_request` | −0.05 | May need ops team confirmation |
| `complaint` | −0.40 | Human must always handle |

**3. Length penalty**

If the reply contains fewer than 20 words, −0.05 is applied (likely a degenerate response).

**Action thresholds**

| Score | Action |
|---|---|
| ≥ 0.85 | `auto_send` |
| 0.60 – 0.84 | `agent_review` |
| < 0.60 | `escalate` |

Complaints are **always** routed to `escalate` regardless of score. The drafted reply serves as a holding message for the agent.

---

### Test results (5 live runs against Claude API)

| Scenario | Channel | Query type | Score | Action |
|---|---|---|---|---|
| Availability + rate for 2 adults, Apr 20–24 | WhatsApp | `pre_sales_availability` | 0.95 | AUTO_SEND |
| Check-in time + WiFi password | Booking.com | `post_sales_checkin` | 0.93 | AUTO_SEND |
| AC not working — angry guest | Airbnb | `complaint` | 0.50 | ESCALATE ✓ |
| Early check-in + private chef request | Direct | `special_request` | 0.85 | AUTO_SEND |
| Pet policy enquiry | Instagram | `general_enquiry` | 0.90 | AUTO_SEND |

Notable: the pet policy test (Test 5) had no answer in the property context. Claude correctly said "I'll check and get back to you" rather than inventing a policy — the prompt explicitly instructs it to only use provided facts.

---

## Part 2 — Database Schema

See [`schema.sql`](./schema.sql) for full PostgreSQL `CREATE TABLE` statements with inline comments.

**Tables at a glance:**

| Table | Purpose |
|---|---|
| `guests` | One record per real person, across all channels |
| `guest_channel_identities` | Maps channel-specific IDs to a guest |
| `properties` | Villa / property records |
| `reservations` | Bookings linked to guests and properties |
| `conversations` | Thread grouping messages together |
| `messages` | Every inbound and outbound message |
| `ai_processing_log` | Audit trail: classification, draft, confidence, edits |

---

## Part 3 — Thinking

See [`thinking.md`](./thinking.md).
