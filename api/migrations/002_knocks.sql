-- Every early attempt to open a capsule is a knock. The server counts them and tells you when it finally opens.
alter table capsules add column if not exists knocks integer not null default 0;
