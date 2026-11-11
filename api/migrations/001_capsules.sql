create table if not exists capsules (
  id          uuid primary key default gen_random_uuid(),
  message     text not null check (char_length(message) between 1 and 500),
  sealed_at   timestamptz not null default now(),
  unlocks_at  timestamptz not null,
  opened_at   timestamptz,
  check (unlocks_at > sealed_at)
);

create index if not exists capsules_sealed_at_idx on capsules (sealed_at desc);
