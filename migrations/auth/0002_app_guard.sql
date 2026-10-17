CREATE TABLE app_auth_browser (
 id TEXT PRIMARY KEY,
 csrf TEXT NOT NULL,
 epoch INTEGER NOT NULL,
 expires INTEGER NOT NULL,
 window INTEGER NOT NULL,
 starts INTEGER NOT NULL
);
CREATE TABLE app_auth_attempt (
 state TEXT PRIMARY KEY,
 browser TEXT NOT NULL,
 epoch INTEGER NOT NULL,
 status TEXT NOT NULL,
 expires INTEGER NOT NULL
);
CREATE INDEX app_auth_attempt_browser ON app_auth_attempt(browser);
CREATE INDEX app_auth_attempt_expiry ON app_auth_attempt(expires);
