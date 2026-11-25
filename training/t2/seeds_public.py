"""Seed texts for the DOSE1 T2 synthetic generators.

Written from scratch for this prototype in public-style business and everyday English, Dutch
and mixed text. Not taken from Jordan's dictations, chats or notes.

Slot syntax (filled by t2_common.tokens_from_template):
  {NAME} person, {NUM} integer, {MONEY} amount, {DATE} month and day, {TIME} clock time,
  {DAY} weekday, {URL} link, {EMAIL} address, {NEG} negation phrase, {DONT} "don't",
  {CORR_DAY} / {CORR_NUM} / {CORR_NAME}: a superseded value, a cue, then the right value.

Dutch templates use only {NAME} and {EMAIL}, so no English number words leak into Dutch text.
Literal-cue and instruction-as-text sentences are whole protected sentences, not slots.
"""

PROSE = [
    "Hi {NAME}, thanks for the call. I will send the revised quote by {DATE}, and the total comes to {MONEY} including VAT.",
    "Can you confirm the delivery is on {DAY} at {TIME}? Please {NEG} ship anything before we sign off.",
    "The invoice number is {NUM}. Send the payment reminder to {EMAIL} and copy {NAME}.",
    "We need {NUM} units by {DATE}, and the budget stays under {MONEY}.",
    "Please check the docs at {URL} before the workshop on {DAY}.",
    "{NAME} said the flight leaves at {TIME} on {DATE}, so book the hotel for {NUM} nights.",
    "The forecast is {NUM} orders for the quarter and {NUM} for the full year.",
    "The deposit is {MONEY}, and the balance is due on {DATE}.",
    "Our meeting moved to {DAY}. Bring the signed contract, the {NUM} page brief, and the receipts.",
    "Release note for the team: the release is {DATE}, the owner is {NAME}, and we {NEG} push anything before QA signs off.",
    "Please forward the offer to {NAME} at {EMAIL} and tell them the price is {MONEY} per seat.",
    "Ask {NAME} whether the parcel for {NUM} Harbour Lane arrived on {DAY}.",
    "The train to Utrecht leaves at {TIME}, and the seat is number {NUM}.",
    "Send me the final numbers by {DAY}, because the accountant needs them before {DATE}.",
    "The meeting is on Thursday, and the agenda is already in the shared folder.",
    "We agreed to keep the current supplier and review the contract again next spring.",
]

MEETING = [
    "Action items. {NAME} owns the budget review by {DATE}. {NAME} sends the vendor list on {DAY}.",
    "Decision: we keep the team at {NUM} people and review it again on {DAY}.",
    "Owner: {NAME}. Deadline: {DATE}. Status: waiting for the signed quote from {NAME}.",
    "Notes from the call. We agreed on {MONEY} for the pilot, the start date is {DATE}, and {NAME} will chase the legal review.",
    "Next steps are simple: {NAME} books the room for {TIME} on {DAY}, and I write up the summary.",
]

RECIPE = [
    "Mix {NUM} grams of flour with {NUM} millilitres of milk, then rest the dough for {NUM} minutes.",
    "Bake it at {NUM} degrees for {NUM} minutes, until the edges are golden.",
    "Add {NUM} eggs, one at a time, and whisk for {NUM} seconds between each.",
    "For the sauce, use {NUM} cloves of garlic, two tins of tomatoes, and a pinch of salt.",
]

RAMBLE = [
    "So we could maybe move the call to {DAY}, because the team is busy on {DAY}, and honestly that works better for everyone.",
    "Honestly the thing is that the new pricing works for most people, and {NAME} agreed it is fair, so I think we are fine.",
    "We went through the list and everything looks fine, I think, so we can ship it once the tests pass on {DAY}.",
    "It is basically a simple process: you upload the file, check the totals, and then you approve it before {DATE}.",
    "Look, the photos from the trip are great, and the best one is from {DATE}, when we walked along the canal.",
    "Right, so the plan is that {NAME} takes the first shift, then we switch on {DAY}, and yeah, it should be fine.",
]

SELF_CORRECTION = [
    "Let's book it for {CORR_DAY} at {TIME}.",
    "The order is {CORR_NUM} crates for the warehouse, and the invoice goes to {EMAIL}.",
    "Send it to {CORR_NAME} before lunch, and copy {NAME}.",
    "We need {CORR_NUM} chairs and {NUM} tables for {DATE}.",
    "Call {CORR_NAME} about the contract on {CORR_DAY}, and bring {MONEY} in cash.",
]

# Literal cue words used with their ordinary meaning. These must survive untouched.
LITERAL_CUE = [
    "We should scratch the surface on this one before the board sees it.",
    "Please hold on to the receipts for the trip.",
    "Wait for the bus outside the station, then call me.",
    "Scratch that card off the list, it is already paid.",
]

# Dictated instructions that are text to keep, not commands to carry out.
INSTRUCTION = [
    "Tell the AI to summarise this in three bullets.",
    "Dictate the rest of this paragraph in British English.",
    "Write a haiku about the rain on the station roof.",
    "Tell the model to skip the first paragraph and keep the numbers.",
]

DUTCH = [
    "Kun je de factuur vóór vrijdag sturen naar {EMAIL}?",
    "Ik denk dat we het volgende week beter kunnen doen.",
    "Stuur mij de notities, dan lees ik ze vanavond.",
    "Nee, niet doen, we wachten tot maandag.",
    "Kunnen we om {NAME} even bellen over het contract?",
    "Het is best druk deze week, maar het komt wel goed.",
]

MIXED = [
    "Can we move the call to {DAY}, dat past beter in mijn agenda.",
    "Send me the notes from today, dank je wel.",
    "The offer looks fine, maar ik wil eerst nog met {NAME} praten.",
    "Let's do the review on {DAY}, het is even druk nu.",
]

# Typed text. Clean form: the target keeps shorthand and slang, and only typing noise is undone.
TYPED_CHAT = [
    "Hey, are you coming to the thing on {DAY}?",
    "I {DONT} think I can make it till {TIME}, sorry.",
    "Can you send me the {NUM} files asap, please?",
    "Let's just meet at {TIME} and see how it goes.",
    "That was so good, thanks {NAME}!",
    "I think we should wait until {DAY} to decide.",
    "Because the pricing is {MONEY} now, we need to reply today.",
    "Ok, see you then, and {DONT} be late!",
    "{NAME} is waiting for the reply, please send it today.",
]

TYPED_EMAIL = [
    "Hi {NAME}, please confirm order number {NUM} before {DATE}.",
    "The total for the project is {MONEY}, excluding VAT, and I can send the invoice to {EMAIL} today.",
    "Please {NEG} share the link at {URL} with anyone outside the team.",
    "We need the final version by {DAY} so the printer can start on {DATE}.",
    "I {DONT} think {NAME} has seen the update yet, so can you forward it?",
    "Thanks, and let me know if {NAME} still wants the call at {TIME}.",
]

TYPED_NOTES = [
    "Buy {NUM} eggs, milk, and the good bread.",
    "Call the bank about card number {NUM} and check the balance.",
    "The birthday of {NAME} is on {DATE}, so get a card.",
]

TYPED_SLANG = [
    "Idk, yk what? Let's just meet at {TIME} and see.",
    "Pls send the {NUM} files today, thx.",
    "Omg that was so good, thx {NAME} lol.",
    "Tbh I think we should wait til {DAY} to decide.",
    "Ok see u then, {DONT} be late lol.",
    "Gonna send the {MONEY} invoice to {EMAIL} rn.",
]

TYPED_DUTCH = [
    "Ik denk dat we het beter volgende week kunnen doen, wat denk jij?",
    "Kun je de factuur naar {EMAIL} sturen? Dan regel ik de betaling.",
    "Hoi {NAME}, ben je morgen om de middag er?",
    "Ik heb geen zin om vandaag nog te bellen, misschien morgen.",
]

TYPED_MIXED = [
    "Can we do the call on {DAY}, dat past beter in mijn agenda?",
    "Pls stuur me de notes van vandaag, thx!",
    "Ok, I'll send the {NUM} files tonight, dan hebben jullie ze morgen.",
]
