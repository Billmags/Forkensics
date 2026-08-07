# FORKENSICS — TABLE TALK PROPOSAL
**Status: Proposed for V1**

---

## OVERVIEW

A social conversation feature is realistic and important to the Forkensics experience.

Much of the fun happens after the answer is revealed:

> "That's my favorite restaurant! How did I not get that?"
> "I almost guessed chicken parm!"
> "I love that place!"
> "We need to eat there next weekend."

These reactions transform a score into a shared experience.

## RECOMMENDATION

Add challenge-based conversations called **TABLE TALK**.

Table Talk should be included in V1. A full private-messaging system should be deferred.

---

## WHAT IS TABLE TALK?

Table Talk is a shared conversation attached to one particular Forkensics mystery.

Everyone participating in that challenge can eventually see and join the conversation. The food mystery provides the subject of the conversation.

Examples:

- "That's my favorite restaurant!"
- "I thought it was lasagna."
- "How did you recognize that?"
- "We ate there last summer."
- "Now I'm hungry."
- "We need to try this place."

When viewing an old challenge, its Table Talk remains attached to it as part of that mystery's history.

---

## WHAT IS PRIVATE MESSAGING?

Private messaging is a separate conversation between two or more selected people. It is not attached to a particular challenge.

Examples:

- Bill privately messages Tom
- Two players have an ongoing conversation
- Someone starts a group chat unrelated to a mystery
- Messages continue through a separate inbox

A private-messaging system generally requires:

- A conversations list
- A separate inbox
- New-message indicators
- Read and unread status
- Recipient selection
- Conversation creation
- Message requests
- Additional notification settings
- More extensive blocking and reporting
- More complicated privacy controls
- More opportunities for unwanted contact

---

## THE SIMPLE DIFFERENCE

**Table Talk:** "This is what everyone playing this mystery is saying about it."

**Private messaging:** "This is a separate conversation between selected people."

---

## WHY TABLE TALK FITS FORKENSICS

Table Talk strengthens the central game. Private messaging creates a second product inside the app.

Forkensics is a food mystery game — not a general messaging service.

Table Talk keeps conversation:

- Relevant
- Social
- Fun
- Easy to understand
- Connected to the food and the reveal
- Limited to the group and challenge
- Consistent with the premium, uncluttered experience

---

## RECOMMENDED TABLE TALK BEHAVIOR

### 1. Before Guessing

Players who have not locked in a guess cannot read the conversation. They may see something like:

> *6 comments waiting*

This creates curiosity without revealing clues or answers.

### 2. After Guessing

Once a player locks in a guess, Table Talk becomes available to that player. They can comment and react without spoiling the mystery for players who have not guessed.

### 3. After the Reveal

When the challenge ends, Table Talk becomes visible to every eligible group member. The conversation remains attached to the completed challenge.

### 4. Historical Challenges

Players can revisit an old mystery and see:

- The food photograph
- The correct answer (restaurant and city)
- The results
- The Table Talk conversation

---

## V1 TABLE TALK FEATURES

**Include:**

- Short text comments
- A small, curated reaction set
- Simple replies or mentions
- Comment notifications with user controls
- Ability to delete your own comment
- Reporting tools
- Blocking tools
- Basic objectionable-content filtering
- Moderator / administrator removal tools

**Possible reactions:**

❤️ 🤤 😂 😱

The reactions should remain restrained and visually polished. They should support the conversation without cluttering the food photography or results screen.

---

## DO NOT INCLUDE IN V1

Defer:

- Private direct messages
- General group chat rooms
- Read receipts
- Typing indicators
- Voice messages
- Photo attachments in comments
- Complex nested reply trees
- Message requests
- A separate messaging inbox

These features add substantial complexity without improving the central mystery-solving experience.

---

## DESIGN DIRECTION

Table Talk should not dominate the mystery screen. The food remains the hero.

During an active challenge, the interface could show a subtle entry point:

> TABLE TALK  
> *6 comments waiting*

After the player locks in a guess:

> TABLE TALK  
> *Join the conversation*

Following the reveal, Table Talk could appear as a beautifully designed section or pull-up panel beneath the results.

The reveal should flow naturally:

```
Correct answer
  → Winner and results
    → Reactions
      → Table Talk
```

This turns the reveal into an emotional and social payoff.

---

## ANTI-SPOILER RULE

A player who has not locked in a guess must not be able to read Table Talk.

Comments written by players who already guessed must remain hidden from players who are still investigating. After the challenge is revealed, the conversation becomes available to everyone eligible to view that challenge.

**This rule should be enforced by the database — not only hidden by the iPhone interface.**

---

## SAFETY AND APP STORE REQUIREMENTS

Comments are user-generated content. Apple currently requires apps containing user-generated content to provide:

- A method for filtering objectionable material
- A mechanism for reporting offensive content
- Timely responses to reports
- The ability to block abusive users
- Published contact information

These protections are still relevant when conversations primarily occur within private groups.

Reference: [Apple App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

---

## APPLE DESIGN AWARD VALUE

Table Talk can improve Forkensics' design-award aspirations because it creates a defining emotional moment. The reveal becomes more than a score — it becomes a shared experience filled with surprise, recognition, laughter, friendly frustration, and plans to visit restaurants together.

Apple's design principles emphasize creating defining moments and designing around the emotion an experience should inspire.

Reference: [Apple Human Interface Guidelines — Design Principles](https://developer.apple.com/design/human-interface-guidelines/design-principles)

---

## FINAL RECOMMENDATION

**APPROVE:** Challenge-based Table Talk for V1.

**DEFER:** Private messaging, general group chat, and a separate inbox.

---

## NORTH-STAR PURPOSE

Table Talk should capture the conversation that naturally happens around the table after everyone discovers what the food was and where it came from.
