// =============================================================
// seed_events.js - Meridian Trust Bank, Portfolio 4
// Loads 50,000 synthetic mobile-banking events into the
// app_events collection, including a small set of DELIBERATELY
// SUSPICIOUS customers (>=3 LOGIN_FAILED from >=2 cities within
// one hour) so the fraud-screening aggregation returns results.
//
// Run from a normal terminal (NOT inside mongosh):
//   mongosh "mongodb://app_user:app_secret@localhost:27017/meridian_bank" --quiet seed_events.js
// =============================================================

const db = db.getSiblingDB('meridian_bank');
const coll = db.app_events;

// Wipe any previous run so the script is idempotent
coll.deleteMany({});

const EVENT_TYPES   = ['LOGIN', 'LOGIN', 'LOGIN', 'LOGIN_FAILED',
                       'PAGE_VIEW', 'PAGE_VIEW', 'PAGE_VIEW', 'PAGE_VIEW',
                       'PAGE_VIEW', 'PAGE_VIEW', 'TRANSFER_INITIATED', 'LOGOUT'];
const CITIES        = ['Lagos', 'Abuja', 'Port Harcourt', 'Ibadan',
                       'Enugu', 'Kano', 'Benin City', 'Abeokuta'];
const OS_VERSIONS   = ['Android 14', 'Android 15', 'iOS 17', 'iOS 18'];
const APP_VERSIONS  = ['4.0.0', '4.1.0', '4.1.2', '4.2.0', '4.2.1'];
const LOGIN_METHODS = ['password', 'biometric', 'pin'];

function pick(arr)        { return arr[Math.floor(Math.random() * arr.length)]; }
function randInt(min, max){ return Math.floor(Math.random() * (max - min + 1)) + min; }

const DAY_MS  = 24 * 60 * 60 * 1000;
const NOW     = new Date();
const START   = new Date(NOW.getTime() - 30 * DAY_MS);   // events over the last 30 days

function randomDevice() {
  return {
    os:            pick(OS_VERSIONS),
    app_version:   pick(APP_VERSIONS),
    device_id_hash: require('crypto')
      .createHash('sha256')
      .update('dev-' + randInt(1, 4000))
      .digest('hex')
      .substring(0, 12)
  };
}

function randomEvent(customerId, when) {
  const type = pick(EVENT_TYPES);
  const evt = {
    customer_id: customerId,
    session_id:  'sess_' + randInt(100000, 999999),
    event_type:  type,
    device:      randomDevice(),
    location:    { city: pick(CITIES), country: 'NG' },
    timestamp:   when
  };
  if (type === 'LOGIN' || type === 'LOGIN_FAILED') {
    evt.metadata = {
      login_method: pick(LOGIN_METHODS),
      failed_attempts_before: type === 'LOGIN_FAILED' ? randInt(0, 3) : 0
    };
  }
  return evt;
}

// -------------------------------------------------------------
// 1. 49,994 ordinary events across 1,000 customers
// -------------------------------------------------------------
let batch = [];
const ORDINARY = 49994;
for (let i = 0; i < ORDINARY; i++) {
  const when = new Date(START.getTime() + Math.random() * (NOW - START));
  batch.push(randomEvent(randInt(1, 1000), when));
  if (batch.length === 1000) { coll.insertMany(batch); batch = []; }
}
if (batch.length > 0) { coll.insertMany(batch); batch = []; }

// -------------------------------------------------------------
// 2. Six suspicious customers: 4 failed logins each, spread
//    across 3 different cities, all inside ONE hour.
//    Customers 9001-9006, hour = 14:00 on a random recent day.
// -------------------------------------------------------------
const SUSPICIOUS_HOUR = new Date(NOW.getTime() - randInt(1, 5) * DAY_MS);
SUSPICIOUS_HOUR.setHours(14, 0, 0, 0);

const pattern = [
  { city: 'Lagos',        mins: 0  },
  { city: 'Kano',         mins: 12 },
  { city: 'Port Harcourt',mins: 27 },
  { city: 'Abuja',        mins: 41 }
];

for (let c = 9001; c <= 9006; c++) {
  for (const p of pattern) {
    coll.insertOne({
      customer_id: c,
      session_id:  'sess_SUSP' + c,
      event_type:  'LOGIN_FAILED',
      device:      randomDevice(),
      location:    { city: p.city, country: 'NG' },
      timestamp:   new Date(SUSPICIOUS_HOUR.getTime() + p.mins * 60000),
      metadata:    { login_method: 'password', failed_attempts_before: randInt(1, 3) }
    });
  }
}

// -------------------------------------------------------------
// 3. Sanity report
// -------------------------------------------------------------
print('Total events:            ' + coll.countDocuments());
print('LOGIN_FAILED events:     ' + coll.countDocuments({ event_type: 'LOGIN_FAILED' }));
print('Suspicious customers:    6  (ids 9001-9006, ' +
      SUSPICIOUS_HOUR.toISOString().substring(0, 10) + ' 14:00 hour)');
print('DONE - ready to run aggregate_fraud_check.js');
