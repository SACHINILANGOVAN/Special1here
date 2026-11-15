# Forever Connect: Supabase setup and deployment

This guide takes you from an empty Supabase project to a live, persistent Forever Connect. Plan on about 20 minutes, plus SMS-provider signup if you want real text messages.

## Files

| File | What it is |
|---|---|
| `index.html` | The whole app. It now includes sign-in, the chat list, private chats, profiles, and Secret Rooms backed by Supabase. |
| `schema.sql` | The complete database: tables, indexes, triggers, functions, RLS, the storage bucket and its policies, and Realtime. |
| `sw.js` | Service worker for notifications. Taps can now open a specific private chat. |
| `manifest.webmanifest`, `icon.svg` | PWA files (unchanged). |
| `index.original.html`, `sw.original.js` | Backups of the app before the upgrade. **Don't deploy these.** |

---

## 1. Create the Supabase project

1. Go to <https://supabase.com/dashboard> → **New project**.
2. Choose a region close to your users and set a strong database password.
3. Wait until the project is ready.

## 2. Run `schema.sql`

1. Dashboard → **SQL Editor** → **New query**.
2. Paste the **entire** contents of `schema.sql` and click **Run**.
3. You should see `Success. No rows returned`.

The script is idempotent, so you can safely run it again after edits. It creates no demo users, seed data or sample messages. The only rows it inserts are profile rows for auth users that **already exist** in the project, and it inserts nothing when there are none.

It sets up:

- **Tables:** `profiles`, `user_presence`, `conversations`, `conversation_participants`, `messages`, `message_receipts`, `secret_rooms`, `secret_room_participants`, `secret_room_messages`
- **Constraints and indexes:** primary keys, foreign keys, unique and check constraints, and performance indexes
- **Triggers:** `updated_at`, auto-creating a profile on sign-up, syncing a verified phone number, and message guards so only the text can be edited and timestamps can't be faked
- **RPC functions** used by the app
- **RLS:** enabled and policies on every table
- **Storage:** the `avatars` bucket and its policies
- **Realtime:** the publication and the Realtime Authorization policies used by the typing indicator

## 3. Add your project URL and anon key to `index.html`

Dashboard → **Project Settings → API** (or **API Keys**). Copy the **Project URL** and the **anon / publishable** key.

Open `index.html` and search for `SUPABASE_CONFIG`:

```js
const SUPABASE_CONFIG = {
  URL: 'https://YOUR-PROJECT-REF.supabase.co',          // ← your Project URL
  ANON_KEY: 'YOUR-SUPABASE-ANON-OR-PUBLISHABLE-KEY',    // ← your anon / publishable key
  AVATAR_BUCKET: 'avatars',
  USERNAME_EMAIL_DOMAIN: 'users.forever-connect.app',
  DEFAULT_COUNTRY: 'IN'                                 // pre-selected country code (India)
};
```

Only `URL` and `ANON_KEY` are required.

> ⚠️ **Never** put the `service_role` / secret key in the frontend. The anon key is designed to be public. Security comes from RLS, which `schema.sql` sets up.

## 4. Configure Supabase Auth

Dashboard → **Authentication → Sign In / Providers** (on older dashboards: **Authentication → Providers**).

### 4a. Mobile number + OTP

1. Enable **Phone**.
2. Pick an **SMS provider**: Twilio, Twilio Verify, MessageBird, Vonage or Textlocal. Then enter that provider's credentials.
3. Keep **OTP length = 6**. The app expects 6 digits.
4. *(Recommended while developing)* Under **Test phone numbers and OTPs**, add something like `919999999999=123456`. You can then sign in without sending a real SMS. Enter the number without the `+`, as the dashboard shows.

### 4a-dev. Development mode (no SMS provider and no real SMS)

`index.html` has a phone sign-in environment switch in `SUPABASE_CONFIG`:

```js
AUTH_ENV: 'development',              // 'development' | 'production'
```

In **development**:
- Any number you add in Supabase under **Test Phone Numbers and OTPs** signs in with its fixed code, and no SMS is sent. The app doesn't list or restrict numbers; Supabase decides.
- **The fixed OTP codes are stored only in Supabase, never in the app.** Supabase Auth still verifies every code, so authentication is never bypassed. A wrong code is rejected.
- A number that isn't a test number would need a real SMS provider. Until you have one, the app shows a short "couldn't send a code" message for it.
- Keep **Test OTPs Valid Until** set to a future date. Expired test codes stop working.

Supabase dashboard setup for development:
1. **Authentication → Sign In / Providers → Phone** → enable the Phone provider.
2. **Test Phone Numbers and OTPs:** add `919597288925=123456`. That's country code plus number, with no `+` and no spaces. Separate several pairs with commas.
3. **SMS provider fields:** Supabase answers test numbers itself and doesn't call the provider for them, but the form may still require the fields before it will save. Use **Twilio Verify** (only Account SID, Auth Token and a Verify Service SID; Verify services can be created on a Twilio trial). Or, in a **development-only project**, enter non-working placeholder values.
4. Save. In the app: Create account → Mobile → tap the test number → enter `123456`.

### 4a-prod. Production (real users, real SMS)

Keep production SMS configuration separate from development. **Best practice is two Supabase projects:**

| | Development project | Production project |
|---|---|---|
| `AUTH_ENV` | `'development'` | `'production'` |
| SMS provider | Twilio Verify trial, or placeholder values | Real, paid provider credentials (Twilio, Twilio Verify, MessageBird, Vonage, Textlocal) |
| Test phone numbers | Your test numbers | **Remove them all** (or keep only internal QA numbers) |
| `URL` / `ANON_KEY` in `index.html` | Dev project's values | Production project's values |

Before going live:
- Set `AUTH_ENV: 'production'` and empty the `DEV_TEST_PHONES` list.
- Configure real provider credentials, and delete the test numbers from the production project.
- Production mode accepts any number, and Supabase sends real SMS using your **SMS Message** template, e.g. `Your Forever Connect code is {{ .Code }}. Never share it.`

If you use a single project for both, swap to real credentials and remove the test numbers on the day you set `AUTH_ENV` to `'production'`.

### 4b. Username + password

Username accounts use Supabase Auth's e-mail/password provider behind the scenes. A username is stored as `<username>@<USERNAME_EMAIL_DOMAIN>`, and no e-mail is ever sent. Passwords are hashed and checked only by Supabase Auth. The database never stores or sees them.

1. Enable **Email**.
2. Turn **OFF "Confirm email"**. This is required, because otherwise sign-up waits for a confirmation e-mail that can never arrive.
3. *(Recommended)* **Authentication → Sign In / Providers → Email → Minimum password length:** set it to 8, to match the app.
4. If sign-up fails with *"Email address … is invalid"*, set `USERNAME_EMAIL_DOMAIN` in `index.html` to a domain you own. No mail is sent to it.

### 4c. Secret Room without an account (anonymous sign-ins)

The sign-in screen has a **Secret Room · no account** button. People who use it can create a room or enter a 6-digit code without registering. Behind the scenes this is a Supabase **anonymous sign-in**: a real, but nameless, auth user.

1. **Authentication → Sign In / Providers** → turn on **Allow anonymous sign-ins** and save.
2. *(Recommended)* **Authentication → Rate Limits**: keep the anonymous sign-in limit low (the default of 30 per hour per IP is fine). Turn on **CAPTCHA protection** (Authentication → Attack Protection) if you see abuse.

What guests can and can't do:
- Guests only see Secret Rooms. Chats, search and groups are hidden in the app, and the database refuses them too (`search_users`, `get_or_create_direct_conversation` and `create_group` raise `account_required`).
- A guest's rooms are kept on that device (the anonymous session is stored in the browser). Chat, photos and videos stay available until the room's owner deletes the room or changes its code.
- If a guest taps **Leave guest mode** or clears the browser's data, that guest identity is gone. Their seat in a room stays taken until the owner deletes the room or changes its code.

Until this setting is on, the button shows "Secret Rooms without an account aren't enabled on the server yet".

### 4d. General

- **Allow new users to sign up:** ON.
- **Authentication → URL Configuration → Site URL:** set it to your deployed URL, e.g. `https://love.example.com`. The app doesn't use e-mail links, but it's good practice.
- **Rate limits** (Authentication → Rate Limits): the defaults are sensible. Raise the SMS limit only if you need to.

## 5. Storage (profile photos)

`schema.sql` already creates the bucket and its policies:

- Bucket **`avatars`**: public read, 2 MB limit, JPEG/PNG/WebP only.
- Users can upload, replace and delete **only inside their own folder** (`<their user id>/…`).
- A profile can only point at a photo in the owner's own folder, enforced by a check constraint.

To verify: Dashboard → **Storage** should show `avatars` marked **Public**. Under **Policies**, you should see four `avatars: owner can …` policies on `storage.objects`.

If you prefer to create the bucket by hand, do it before running `schema.sql`: **Storage → New bucket** → name `avatars`, Public ON, file size limit 2 MB, allowed MIME types `image/jpeg, image/png, image/webp`. Then run `schema.sql`; it adopts the existing bucket.

### Group chats

Groups use the same tables as private chats:
- A conversation has `is_group`, a title, a photo and member roles (`admin` / `member`).
- Up to 256 people per group.
- Creating a group and adding or removing members all happen in server functions (`create_group`, `add_group_members`, `remove_group_member`, `set_group_admin`, `leave_group`, `update_group`), which check admin rights.
- Only members can read a group's messages and files, and removed members lose access immediately.
- Voice and video calls stay one-to-one.

Re-run `schema.sql` to add groups to an existing project.

### Private-chat attachments (bucket `chat-media`)

`schema.sql` also creates a **private** bucket called `chat-media` for photos, videos and files sent in private chats. Each file can be up to 50 MB, which is the Supabase free-plan limit.

- Files are stored as `<conversation id>/<sender id>/<file>`.
- Only the two people in the conversation can open them, through short-lived signed links.
- You can only upload into your own folder, and a message can only point at a file its sender uploaded to that conversation.

**Upgrading an existing project:** re-run the whole `schema.sql` in the SQL Editor. It's safe to run again, and it adds the attachment columns, the bucket and its policies. Until you do, private chats keep working for text, and the 📎 button tells you the database needs the update.

### Secret Room photos and videos (bucket `room-media`)

`schema.sql` creates a second **private** bucket, `room-media`, so Secret Room photos and videos are kept until the room is deleted (50 MB per file).

- Files are stored as `<room id>/<sender id>/<file>`. Only the room's members can open them, through short-lived signed links.
- You can only upload into your own folder. The uploader or the room's owner can delete files.
- When the owner deletes a room or changes its code, the owner's app first deletes the room's files, then the room. (If a room disappears another way, for example when the owner's account is deleted, its files stay in the bucket. You can remove them in **Storage**.)
- Photos and videos still go device-to-device too when both people are online, so they appear instantly.

Until you re-run `schema.sql`, room photos and videos keep working live-only, as before.

## 6. RLS and Realtime: verify

**RLS:** Dashboard → **Table Editor**. Every table listed in step 2 should show **RLS enabled**. Dashboard → **Authentication → Policies** lists the policies.

What RLS guarantees:

| Data | Who can read | Who can write |
|---|---|---|
| Profiles | You, plus people who share a conversation or room with you. The phone column is never readable by any client. | You (username, display name, photo only) |
| Presence | You, plus your contacts | Only through `touch_presence` |
| Conversations, participants | Participants only | Only through `get_or_create_direct_conversation` |
| Messages | Participants only | Insert: a participant, as themselves. Update: the sender, text only. |
| Read receipts | The recipient and the message's sender | Only through `mark_delivered` / `mark_conversation_read` |
| Secret rooms, members | Room members only | Only through the room functions |
| Room messages | Room members, and only messages sent after they joined | Insert: a member, as themselves. Update: the sender, text only. |

**Realtime:** Dashboard → **Database → Publications → `supabase_realtime`** should include `messages`, `message_receipts`, `user_presence`, `secret_room_messages` and `conversation_participants`.

**Private-chat voice and video calls** need no extra tables:
- Ringing, accept/decline and connection setup travel over each conversation's private Realtime channel (`dm:<conversation id>`), which the `realtime.messages` policies restrict to the two participants.
- Audio and video go directly device-to-device over WebRTC, using the same STUN/relay servers as Secret Room calls.
- For more reliable calls on strict mobile or office networks, add your own TURN server to `CONFIG.CUSTOM_ICE_SERVERS` in `index.html`.

Dashboard → **Realtime → Settings**: keep **"Allow public access"** turned **ON**.
- Chat updates use Postgres Changes, which are still filtered per user by RLS.
- The typing indicator uses **private** channels authorized by the `realtime.messages` policies in `schema.sql`.

## 7. Deploy

The app is static files. No Node.js, build step or server code is needed. It **must be served over HTTPS**, because notifications, the service worker, calls and the camera all require a secure context.

Upload these four files to the same folder:

```
index.html   sw.js   manifest.webmanifest   icon.svg
```

Any static host works. Pick one:

- **Netlify:** <https://app.netlify.com/drop>. Drag the folder in. Done.
- **Cloudflare Pages / Vercel:** create a project from the folder or a Git repo, with no build command and the output directory set to the root.
- **GitHub Pages:** push the files to a repo, then Settings → Pages → Deploy from branch.
- **Your own server:** any web server with HTTPS.

Then set **Site URL** (step 4d) to the deployed address.

For local testing, `http://localhost` also counts as secure. For example, run `python -m http.server 8080` in the folder and open <http://localhost:8080>.

## 8. Smoke test, with two browsers or devices

1. **A:** Create account → Username → pick a username and password → you land on **Chats**.
2. **B:** Create account → Mobile → enter the number → enter the OTP → choose a username → **Chats**.
3. **A:** tap 🔍 → search B's username (or B's full mobile number) → open the chat → send a message.
4. **B:** the chat appears with an unread badge. Open it, and A's ticks turn to read ✓✓.
5. Type on one side; **typing…** shows on the other. Close B's tab; A sees **last seen …**.
6. Refresh both. All history is still there.
7. **Secret Room:** A → Secret Room → Create → share the code → B → Enter Secret Code. You're connected peer-to-peer as before, and text, photos and videos are saved. Refresh either side and the room resumes. Delete the room and its history and media are erased.
8. **Guest:** in a private window, tap **Secret Room · no account** → enter a name → Enter Secret Code with a room code from A. The room works the same way, and it appears under **Recent rooms**.
9. **Recent rooms:** on A, create a second room, then tap the first room under **Recent rooms**. It reopens without the code.

---

## How the Secret Room works now

Everything that worked before still works the same way: the 6-digit code, live peer-to-peer messages, photos, videos, voice and video calls, reply, edit, rename, and the reconnect logic. Supabase adds the following.

- **Server-side room privacy.** Creating a room registers its code in your account. Joining validates the code in the database and claims the single guest seat. The host's device also checks every incoming peer connection against the database, so knowing the code alone isn't enough to impersonate the guest.
- **Persistence.** Text messages are saved to `secret_room_messages`. A room survives refreshes, closed tabs and device changes: sign in anywhere and it resumes.
- **Realtime fallback.** If the direct WebRTC link can't connect, for example on a strict network or when the partner is offline, text still arrives through Supabase Realtime.
- **Photos and videos are stored** in the private `room-media` bucket, and also go device-to-device when both people are online.
- **Several rooms per person, with Recent rooms.** Creating or joining another room no longer closes the current one. Every room you created or joined is listed under **Recent rooms** on the Secret Room screen, and you can reopen any of them with one tap, without the code. Each person can own up to 20 rooms. The ⋯ menu on a recent room lets you copy its code, delete it (owner) or leave it (guest).
- **No account needed.** Guests can use Secret Rooms through anonymous sign-in (step 4c).
- **Deleting the room or changing its code permanently deletes** the room, its members, its history and its stored media, matching the original privacy promise. **Leaving** as a guest frees the seat, and a new guest can only see messages sent after they join.

## Security notes and limits

- The anon key is public by design. Every read and write is authorized by RLS and by `security definer` functions that check `auth.uid()`.
- Phone numbers are copied only from **verified** auth phones and are never returned to other users. Searching by phone requires the exact full number.
- Room codes are 6 digits, as before. A room accepts exactly one guest, and new guests can't read earlier history. If you need stronger protection against code guessing, add per-user rate limiting at the API gateway or an Edge Function.
- Messages are protected in transit (TLS) and at rest by Supabase. They are not end-to-end encrypted, so whoever administers the Supabase project can technically read them.

## Troubleshooting

| Symptom | Fix |
|---|---|
| "Supabase isn't configured yet" on the sign-in screen | Fill in `SUPABASE_CONFIG.URL` and `ANON_KEY` in `index.html`. |
| "The database isn't set up yet" or "Couldn't load your profile" | Run `schema.sql` (step 2). |
| "Mobile sign-in isn't enabled on the server yet" | Enable the Phone provider and configure an SMS provider (step 4a). |
| "No account uses this number yet" | That number hasn't registered. Use **Create account**. |
| "We couldn't send a code to this number" | Add the number in Supabase → Phone → **Test Phone Numbers and OTPs** (country code, no `+`), keep **Test OTPs Valid Until** in the future, or configure a real SMS provider (step 4a). |
| Username sign-up says to turn off e-mail confirmation | Turn off **Confirm email** (step 4b). |
| "Email address … is invalid" on username sign-up | Set `USERNAME_EMAIL_DOMAIN` to a domain you own (step 4b). |
| Profile photo upload fails | Check that the `avatars` bucket and its policies exist (step 5). |
| Messages only appear after a refresh | Check that the Realtime publication includes the four tables (step 6). |
| No "typing…" indicator (console: *typing channel unavailable*) | Re-run `schema.sql` to recreate the Realtime Authorization policies (step 6). |
| Notifications or calls don't work | Serve the site over HTTPS (step 7). On iPhone, add it to the Home Screen first. |
| Notifications appear only as a status-bar icon, with no pop-up banner | The phone decides this, not the app. Use **Settings → Test notification banner** in the app, then follow its steps: install the app to the home screen, set its notifications to Alerting, and turn on "Pop on screen". The app is kept alive only while it's open in the background. For alerts after the phone closes it, you'd need Web Push (not included). |
| "Secret Rooms without an account aren't enabled" | Turn on **Allow anonymous sign-ins** (step 4c). |
| Room photos show "shared live · not stored" | Re-run `schema.sql` to add the `room-media` bucket. Files sent before that weren't stored. |
