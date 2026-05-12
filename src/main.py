"""
Nistula Guest Message Handler
Receives inbound guest messages, normalises them, classifies query type,
drafts a reply via Claude API, and returns a confidence-scored response.
"""

import os
import uuid
import httpx
from datetime import datetime
from typing import Optional

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
import anthropic
from dotenv import load_dotenv

load_dotenv()

app = FastAPI(
    title="Nistula Guest Message Handler",
    description="Webhook endpoint that normalises guest messages and drafts AI replies",
    version="1.0.0",
)

# ──────────────────────────────────────────────
# Pydantic models
# ──────────────────────────────────────────────

VALID_SOURCES = {"whatsapp", "booking_com", "airbnb", "instagram", "direct"}

QUERY_TYPES = [
    "pre_sales_availability",
    "pre_sales_pricing",
    "post_sales_checkin",
    "special_request",
    "complaint",
    "general_enquiry",
]


class InboundMessage(BaseModel):
    source: str
    guest_name: str
    message: str
    timestamp: str
    booking_ref: Optional[str] = None
    property_id: Optional[str] = None


class NormalisedMessage(BaseModel):
    message_id: str
    source: str
    guest_name: str
    message_text: str
    timestamp: str
    booking_ref: Optional[str] = None
    property_id: Optional[str] = None
    query_type: str


class WebhookResponse(BaseModel):
    message_id: str
    query_type: str
    drafted_reply: str
    confidence_score: float
    action: str


# ──────────────────────────────────────────────
# Mock property context
# ──────────────────────────────────────────────

PROPERTY_CONTEXT = {
    "villa-b1": """
PROPERTY DETAILS — Villa B1, Assagao, North Goa
================================================
Bedrooms       : 3
Max Guests     : 6
Private Pool   : Yes
Check-in       : 2:00 PM
Check-out      : 11:00 AM
WiFi Password  : Nistula@2024
Caretaker      : On-site, available 8 AM – 10 PM
Chef on Call   : Yes (pre-booking required, at least 24 hrs notice)

RATES
-----
Base Rate         : INR 18,000 per night (up to 4 guests)
Extra Guest       : INR 2,000 per night per additional person (max 2 extra guests)

AVAILABILITY
------------
April 20–24, 2026 : AVAILABLE

CANCELLATION POLICY
-------------------
Free cancellation up to 7 days before check-in. No refund within 7 days.

NEARBY
------
Closest beach     : Anjuna (~10 min drive)
Nearest pharmacy  : 5 min drive
Airport           : Dabolim (~1 hr), Mopa (~45 min)
"""
}

DEFAULT_PROPERTY_CONTEXT = PROPERTY_CONTEXT["villa-b1"]  # fallback


def get_property_context(property_id: Optional[str]) -> str:
    if property_id and property_id in PROPERTY_CONTEXT:
        return PROPERTY_CONTEXT[property_id]
    return DEFAULT_PROPERTY_CONTEXT


# ──────────────────────────────────────────────
# Normalisation
# ──────────────────────────────────────────────

def normalise_message(raw: InboundMessage, query_type: str) -> NormalisedMessage:
    """Convert raw inbound payload into the unified schema."""
    return NormalisedMessage(
        message_id=str(uuid.uuid4()),
        source=raw.source.lower(),
        guest_name=raw.guest_name.strip(),
        message_text=raw.message.strip(),
        timestamp=raw.timestamp,
        booking_ref=raw.booking_ref,
        property_id=raw.property_id,
        query_type=query_type,
    )


# ──────────────────────────────────────────────
# Query classification (via Claude)
# ──────────────────────────────────────────────

def build_classification_prompt(message_text: str) -> str:
    return f"""Classify the following guest message into exactly one of these query types:

- pre_sales_availability  → asking about dates/availability before booking
- pre_sales_pricing       → asking about rates, costs, pricing before booking
- post_sales_checkin      → asking about check-in time, WiFi, directions, house info after booking
- special_request         → requesting extra services (early check-in, airport transfer, chef, etc.)
- complaint               → expressing dissatisfaction, reporting a problem
- general_enquiry         → any other question (pets, parking, amenities, etc.)

Guest message:
\"\"\"{message_text}\"\"\"

Reply with ONLY the query type label (e.g. pre_sales_availability). No explanation."""


def classify_query(client: anthropic.Anthropic, message_text: str) -> str:
    """Use Claude to classify the message into a query type."""
    try:
        response = client.messages.create(
            model="claude-sonnet-4-20250514",
            max_tokens=20,
            messages=[
                {"role": "user", "content": build_classification_prompt(message_text)}
            ],
        )
        raw = response.content[0].text.strip().lower().replace("-", "_")
        # Validate — fall back to general_enquiry if unexpected
        return raw if raw in QUERY_TYPES else "general_enquiry"
    except Exception:
        return "general_enquiry"


# ──────────────────────────────────────────────
# Reply drafting (via Claude)
# ──────────────────────────────────────────────

def build_reply_prompt(normalised: NormalisedMessage, property_ctx: str) -> str:
    booking_line = (
        f"Booking Reference : {normalised.booking_ref}"
        if normalised.booking_ref
        else "Booking Reference : Not provided (pre-booking enquiry)"
    )

    source_style = {
        "whatsapp": "warm, conversational, use line breaks for readability",
        "booking_com": "professional and concise",
        "airbnb": "friendly, Airbnb host tone",
        "instagram": "casual and welcoming, keep it short",
        "direct": "warm and personalised",
    }.get(normalised.source, "professional and warm")

    return f"""You are a hospitality concierge for Nistula Villas, a premium villa rental in Goa, India.
Draft a reply to the guest message below.

PROPERTY CONTEXT
{property_ctx}

GUEST DETAILS
Name              : {normalised.guest_name}
Channel           : {normalised.source}
{booking_line}
Query Type        : {normalised.query_type}

GUEST MESSAGE
\"\"\"{normalised.message_text}\"\"\"

INSTRUCTIONS
- Address the guest by first name
- Answer every question accurately using ONLY the property context above
- Tone: {source_style}
- If asked about availability April 20–24: confirm it is available and provide the rate
- For pricing with 2 adults: base rate applies (INR 18,000/night, up to 4 guests)
- Do NOT invent information not in the context
- End with an offer to help further or a warm closing
- Keep reply under 120 words unless detail genuinely requires more
- Do NOT include a subject line or email header

Write the reply now:"""


def draft_reply(client: anthropic.Anthropic, normalised: NormalisedMessage, property_ctx: str) -> tuple[str, float]:
    """
    Call Claude to draft a reply. Returns (reply_text, raw_confidence).
    raw_confidence is derived from stop_reason and token usage heuristics
    and is further adjusted by query_type in compute_confidence().
    """
    response = client.messages.create(
        model="claude-sonnet-4-20250514",
        max_tokens=400,
        messages=[
            {"role": "user", "content": build_reply_prompt(normalised, property_ctx)}
        ],
    )

    reply_text = response.content[0].text.strip()
    stop_reason = response.stop_reason  # "end_turn" | "max_tokens" | ...

    # Heuristic base confidence
    base = 0.90 if stop_reason == "end_turn" else 0.55

    return reply_text, base


# ──────────────────────────────────────────────
# Confidence scoring
# ──────────────────────────────────────────────

def compute_confidence(base: float, query_type: str, reply_text: str) -> float:
    """
    Final confidence is a blend of:
      1. base     — whether Claude stopped cleanly (0.90) or hit token limit (0.55)
      2. type_adj — query types we have full context for score higher
      3. length   — very short replies for complex questions penalised slightly
      4. complaint — always capped at 0.59 to force escalation path

    Score → action:
      ≥ 0.85  → auto_send
      0.60–0.84 → agent_review
      < 0.60  → escalate
    """
    type_adjustment = {
        "pre_sales_availability": +0.05,   # full context available
        "pre_sales_pricing":      +0.04,
        "post_sales_checkin":     +0.03,
        "special_request":        -0.05,   # may need ops team input
        "complaint":              -0.40,   # always escalate
        "general_enquiry":         0.00,
    }.get(query_type, 0.0)

    word_count = len(reply_text.split())
    length_penalty = -0.05 if word_count < 20 else 0.0

    score = base + type_adjustment + length_penalty
    score = round(max(0.0, min(1.0, score)), 2)
    return score


def action_from_score(score: float, query_type: str) -> str:
    if query_type == "complaint":
        return "escalate"
    if score >= 0.85:
        return "auto_send"
    if score >= 0.60:
        return "agent_review"
    return "escalate"


# ──────────────────────────────────────────────
# Webhook endpoint
# ──────────────────────────────────────────────

@app.post("/webhook/message", response_model=WebhookResponse)
async def handle_message(payload: InboundMessage):
    # Validate source
    if payload.source.lower() not in VALID_SOURCES:
        raise HTTPException(
            status_code=422,
            detail=f"Invalid source '{payload.source}'. Must be one of: {', '.join(VALID_SOURCES)}",
        )

    api_key = os.getenv("ANTHROPIC_API_KEY")
    if not api_key:
        raise HTTPException(status_code=500, detail="ANTHROPIC_API_KEY not configured")

    client = anthropic.Anthropic(api_key=api_key)

    try:
        # 1. Classify
        query_type = classify_query(client, payload.message)

        # 2. Normalise
        normalised = normalise_message(payload, query_type)

        # 3. Get property context
        property_ctx = get_property_context(normalised.property_id)

        # 4. Draft reply
        reply_text, base_confidence = draft_reply(client, normalised, property_ctx)

        # 5. Score
        confidence = compute_confidence(base_confidence, query_type, reply_text)
        action = action_from_score(confidence, query_type)

        return WebhookResponse(
            message_id=normalised.message_id,
            query_type=query_type,
            drafted_reply=reply_text,
            confidence_score=confidence,
            action=action,
        )

    except anthropic.APIStatusError as e:
        raise HTTPException(status_code=502, detail=f"Claude API error: {e.message}")
    except anthropic.APIConnectionError:
        raise HTTPException(status_code=503, detail="Could not reach Claude API")
    except Exception as e:
        raise HTTPException(status_code=500, detail=f"Internal error: {str(e)}")


# ──────────────────────────────────────────────
# Health check
# ──────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok", "timestamp": datetime.utcnow().isoformat() + "Z"}


@app.get("/")
async def root():
    return {
        "service": "Nistula Guest Message Handler",
        "version": "1.0.0",
        "endpoints": {
            "webhook": "POST /webhook/message",
            "health": "GET /health",
            "docs": "GET /docs",
        },
    }
