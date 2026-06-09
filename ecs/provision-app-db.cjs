// provision-app-db.cjs — DB worker for provision-app-db.sh. Creates an app's
// per-app roles + database + grants on the SHARED staging RDS, mirroring wrapper:
//   <app>_migrator  owns the DB (USAGE+CREATE on public)        -> migrations/DDL
//   <app>_app       SELECT/INSERT/UPDATE/DELETE (+ future)      -> runtime
//   <app>_viewer    SELECT (+ future)                           -> read-only
// Idempotent: re-running rotates passwords and re-applies grants. Connects via
// the postgres.js client from the backend workspace (path passed in PG_MODULE).
const postgres = require(process.env.PG_MODULE);
const { APP, DB, MASTER_URL, PW_MIG, PW_APP, PW_VIEW } = process.env;

// Hard guards: identifiers and passwords are interpolated into DDL, so validate.
const ident = (s) => { if (!/^[a-z][a-z0-9_]*$/.test(s)) throw new Error(`bad identifier: ${s}`); return s; };
const hex = (s) => { if (!/^[0-9a-f]{8,}$/.test(s)) throw new Error('bad password'); return s; };
const mig = ident(`${APP}_migrator`), app = ident(`${APP}_app`), viewer = ident(`${APP}_viewer`);
const dbName = ident(DB);
hex(PW_MIG); hex(PW_APP); hex(PW_VIEW);

(async () => {
  const admin = postgres(MASTER_URL, { ssl: { rejectUnauthorized: false }, max: 1 });

  // 1. Roles — create, or rotate the password if they already exist.
  const ensureRole = async (name, pw) => {
    const [{ exists }] = await admin`SELECT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=${name}) AS exists`;
    await admin.unsafe(`${exists ? 'ALTER' : 'CREATE'} ROLE ${name} LOGIN PASSWORD '${pw}'`);
    console.log(`  ✓ role ${name}`);
  };
  await ensureRole(mig, PW_MIG);
  await ensureRole(app, PW_APP);
  await ensureRole(viewer, PW_VIEW);

  // dbadmin must be a member of the owner role to CREATE DATABASE ... OWNER mig
  // and to ALTER DEFAULT PRIVILEGES FOR ROLE mig below.
  await admin.unsafe(`GRANT ${mig} TO CURRENT_USER`);

  // 2. Database owned by the migrator role (create only if missing).
  const [{ exists: dbex }] = await admin`SELECT EXISTS(SELECT 1 FROM pg_database WHERE datname=${dbName}) AS exists`;
  if (!dbex) { await admin.unsafe(`CREATE DATABASE ${dbName} OWNER ${mig}`); console.log(`  ✓ database ${dbName}`); }
  else console.log(`  • database ${dbName} already exists`);
  await admin.end();

  // 3. Privileges inside the app database.
  const dbUrl = MASTER_URL.replace('/postgres?', `/${dbName}?`);
  const d = postgres(dbUrl, { ssl: { rejectUnauthorized: false }, max: 1 });
  await d.unsafe(`GRANT USAGE, CREATE ON SCHEMA public TO ${mig}`);
  await d.unsafe(`GRANT USAGE ON SCHEMA public TO ${app}, ${viewer}`);
  // Existing objects (none on first run; harmless to repeat after tables exist).
  await d.unsafe(`GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${app}`);
  await d.unsafe(`GRANT SELECT ON ALL TABLES IN SCHEMA public TO ${viewer}`);
  await d.unsafe(`GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${app}`);
  await d.unsafe(`GRANT SELECT ON ALL SEQUENCES IN SCHEMA public TO ${viewer}`);
  // Future objects the migrator creates inherit the same grants.
  await d.unsafe(`ALTER DEFAULT PRIVILEGES FOR ROLE ${mig} IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${app}`);
  await d.unsafe(`ALTER DEFAULT PRIVILEGES FOR ROLE ${mig} IN SCHEMA public GRANT SELECT ON TABLES TO ${viewer}`);
  await d.unsafe(`ALTER DEFAULT PRIVILEGES FOR ROLE ${mig} IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO ${app}`);
  await d.unsafe(`ALTER DEFAULT PRIVILEGES FOR ROLE ${mig} IN SCHEMA public GRANT SELECT ON SEQUENCES TO ${viewer}`);
  console.log('  ✓ grants + default privileges');
  await d.end();
})().catch((e) => { console.error('PROVISION ERROR:', e.message); process.exit(1); });
