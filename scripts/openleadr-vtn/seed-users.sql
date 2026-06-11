-- Default OAuth clients for the local OpenADR VTN (openleadr-vtn).
-- Mirrors upstream openleadr-rs fixtures/users.sql AT TAG v0.2.3 (the scope
-- enum differs between releases — keep this in sync with the tag pinned in
-- docker-compose.yml), made idempotent so the one-shot seed container can run
-- on every `docker compose up`.
--
-- bl-client  / bl-client  : business-logic side (the aggregator bridge) —
--                           write_programs + write_events.
-- ven-client-client-id / ven-client : VEN side — write_reports etc.
-- Secrets are argon2id hashes of the literal strings above (dev only).

INSERT INTO "user" (id, reference, description, scopes, created, modified)
VALUES ('bl-client', 'bl-client-ref', null,
        '{"read_all", "write_vens_bl", "write_programs", "write_events", "write_users"}',
        '2024-07-25 08:31:10.776000 +00:00', '2024-07-25 08:31:10.776000 +00:00')
ON CONFLICT (id) DO NOTHING;

INSERT INTO user_credentials (user_id, client_id, client_secret)
VALUES ('bl-client', 'bl-client',
        '$argon2id$v=19$m=16,t=2,p=1$MWt1QVNFdHdlZVJhNEZzUA$Rmkguwgaz+A2GWIaDRtv8w') -- secret: bl-client
ON CONFLICT (client_id) DO NOTHING;

INSERT INTO "user" (id, reference, description, scopes, created, modified)
VALUES ('ven-client', 'ven-client-ref', 'desc',
        '{"read_targets", "read_ven_objects", "write_reports", "write_subscriptions", "write_vens_ven"}',
        '2024-07-25 08:31:10.776000 +00:00', '2024-07-25 08:31:10.776000 +00:00')
ON CONFLICT (id) DO NOTHING;

INSERT INTO user_credentials (user_id, client_id, client_secret)
VALUES ('ven-client', 'ven-client-client-id',
        '$argon2id$v=19$m=16,t=2,p=1$YWlOSE8xRGFVdVVIa212Ug$tjmQC+zNC3QXc9K8mEXRrA') -- secret: ven-client
ON CONFLICT (client_id) DO NOTHING;
