# Getting Started with OpenWebUI (agent.photondatum.space)
**Last Updated:** 2026-09-16
**Audience:** New and existing OpenWebUI users on `agent.photondatum.space`

## What this is for

Two things, in order:

1. **Getting access** to `agent.photondatum.space` in the first place, if you don't have
   it yet.
2. **Optionally connecting your own OpenAI, Groq, or Mistral account**, once you're in,
   if you want models beyond the free built-in ones.

Adding your own OpenAI, Groq, or Mistral account is completely optional — agent.photondatum.space already hosts several useful models locally, free to use, with no setup required. Most people won't need to do anything beyond getting access (Part 1 below). Only come back to Part 2 if you specifically want a model that isn't available locally.

If you already have access and just want the second part, skip ahead to
[Part 2 — Optional: Connect Your Own Cloud Models](#part-2--optional-connect-your-own-cloud-models).

---

## Part 1 — Getting Access to agent.photondatum.space

Access is controlled through Authentik, the sign-in system behind
`agent.photondatum.space`. Which path applies to you depends on how you're being added.

### If you received an invite link

Your admin generated this specifically for you.

1. Open the invite link you were sent.
2. Fill in a username, your name, email, and a password.
3. Submit — your account is created **active** immediately, and you're signed straight
   into the chat interface. Nothing further to do.

### If you don't have an invite link

1. Go to `https://auth.photondatum.space` and sign in with one of the available social
   providers (GitHub, Google, or GitLab).
2. Your account is created, but starts **inactive** — you won't be able to use anything
   yet.
3. Let your admin know you've signed up so they can activate your account and grant it
   the right access. There's no notification sent automatically; a quick message to them
   is the fastest way to get unblocked.
4. Once activated, go to `https://agent.photondatum.space` — you'll be signed in
   automatically, no separate password needed for the chat app itself.

### Either way, once you're in

Visiting `https://agent.photondatum.space` from then on signs you in automatically —
there's no separate OpenWebUI login screen. You already have access to a set of free,
self-hosted models with no further setup: just pick one from the model list and start
chatting.

**A note on the small tags you'll see (like `strong-1`, `strong-2`, `strong-3`):** the free
models run on a few different physical machines behind the scenes, and each one carries a
tag showing which machine it's on. `strong` just means it's one of our capable machines —
right now that's all of them, so the number is the only thing that varies: `strong-1` is
our main, most powerful machine, `strong-2` and `strong-3` are still solid but slightly
more modest workstations. You don't need to pick based on this — any of them will work
well for typical chatting — but it's useful context if a response feels slower than usual,
or if a specific machine happens to be temporarily offline (it's someone's actual
computer, occasionally restarted or asleep). If a model you picked doesn't respond, just
try another one from the list.

---

## Part 2 — Optional: Connect Your Own Cloud Models

If you'd also like to use **OpenAI (GPT), Groq, or Mistral**, you can connect your own
personal account for each. This is entirely separate from the built-in models: it uses
your own API key, so usage is billed to you, and nobody else can see or use your
connection.

**A note on Claude:** Claude can't be added this way — see [why](#a-note-on-claude) at
the bottom. If you need Claude access, contact your admin directly.

### Before you start

You'll need your own API key from whichever provider(s) you want to use:

| Provider | Get a key at |
|---|---|
| OpenAI | https://platform.openai.com/api-keys |
| Groq | https://console.groq.com/keys |
| Mistral | https://console.mistral.ai/api-keys |

Each of these is a paid account you set up and manage yourself — OpenWebUI just needs
the key to make requests on your behalf.

---

### Step 1 — Open your connection settings

In OpenWebUI, click your profile → **Settings** → **Connections** tab → **Manage Direct
Connections**.

### Step 2 — Add a connection

Click the **+** button to add a new connection. For each provider you want, enter:

| Provider | Base URL | API Key |
|---|---|---|
| OpenAI | `https://api.openai.com/v1` | your OpenAI key |
| Groq | `https://api.groq.com/openai/v1` | your Groq key |
| Mistral | `https://api.mistral.ai/v1` | your Mistral key |

Repeat for each provider — you can add all three if you like.

### Step 3 — Save and select your model

Save the connection. Open the model picker at the top of a new chat — models from your
connection should now appear alongside the built-in ones. Pick one and start chatting.

**If nothing shows up:** double-check the base URL has no typo or trailing slash issue,
and that the key is valid (test it directly with the provider if unsure). A wrong key
usually shows as an error on your first message rather than an empty model list.

---

### A note on Claude

Claude isn't available through this same "Add Connection" flow, and it's a limitation of
how OpenWebUI's personal connections work, not something specific to this setup: that
feature only speaks the same request format OpenAI, Groq, and Mistral all use. Claude's
own API uses a different format entirely, so pointing a personal connection at it simply
doesn't work.

If you need Claude access day-to-day, ask your admin — access is currently handled a
different way and isn't self-service.

---

## Reference

- Official OpenWebUI documentation on this feature: https://docs.openwebui.com/features/chat-conversations/direct-connections/
