CREATE TABLE direct_conversation (
  id uuid PRIMARY KEY,
  participant_low uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  participant_high uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_message_at timestamptz,
  UNIQUE (participant_low, participant_high),
  CHECK (participant_low < participant_high)
);

CREATE INDEX direct_conversation_inbox_idx
  ON direct_conversation(last_message_at DESC NULLS LAST, created_at DESC);

CREATE TABLE direct_message (
  id uuid PRIMARY KEY,
  conversation_id uuid NOT NULL REFERENCES direct_conversation(id) ON DELETE CASCADE,
  sender_id uuid NOT NULL REFERENCES app_user(id) ON DELETE CASCADE,
  body varchar(2000) NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (char_length(btrim(body)) BETWEEN 1 AND 2000)
);

CREATE INDEX direct_message_history_idx
  ON direct_message(conversation_id, created_at DESC, id DESC);
