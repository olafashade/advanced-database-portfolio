// =============================================================
// mongo-init.js - Meridian Trust Bank, Portfolio 4
// the automatic initialization script for MongoDB 7 container
// mounted to /docker-entrypoint-initdb.d/mongo-init.js:ro
// =============================================================

const bankDB = db.getSiblingDB('meridian_bank');

// create the dedicated application user
bankDB.createUser({
  user: 'app_user',
  pwd: 'app_secret',
  roles: [
    { role: 'readWrite', db: 'meridian_bank' },
    { role: 'dbAdmin', db: 'meridian_bank' }
  ]
});

// pre-create the events collection
bankDB.createCollection('app_events');

// compound index to accelerate the fraud aggregation stage 1 ($match event_type + timestamp)
bankDB.app_events.createIndex({ event_type: 1, timestamp: -1 }, { name: 'idx_event_type_timestamp' });

// index for customer timeline investigations
bankDB.app_events.createIndex({ customer_id: 1, timestamp: -1 }, { name: 'idx_customer_timestamp' });

// index for session tracing
bankDB.app_events.createIndex({ session_id: 1 }, { name: 'idx_session' });

print('>>> [INIT] meridian_bank database, app_user credentials, and indexes initialized successfully.');
