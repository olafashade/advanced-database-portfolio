// =============================================================
// aggregate_fraud_check.js - Meridian Trust Bank, Portfolio 4
// Fraud screening: flag customers with >= 3 failed logins from
// >= 2 distinct cities within a single hour.
//
// Run from a normal terminal (NOT inside mongosh):
//   mongosh "mongodb://app_user:app_secret@localhost:27017/meridian_bank" --quiet aggregate_fraud_check.js
//
// To capture the output as evidence:
//   mongosh "mongodb://app_user:app_secret@localhost:27017/meridian_bank" --quiet aggregate_fraud_check.js > fraud_aggregation_output.txt
// =============================================================

const db = db.getSiblingDB('meridian_bank');

print('============================================================');
print(' Fraud check: >=3 LOGIN_FAILED from >=2 cities in one hour');
print(' Collection : app_events (' + db.app_events.countDocuments() + ' documents)');
print('============================================================\n');

const results = db.app_events.aggregate([
  // Stage 1 - keep only failed logins
  { $match: { event_type: 'LOGIN_FAILED' } },

  // Stage 2 - bucket by customer + hour, collecting the evidence
  { $group: {
      _id: {
        customer: '$customer_id',
        hour:     { $dateTrunc: { date: '$timestamp', unit: 'hour' } }
      },
      attempts: { $sum: 1 },
      cities:   { $addToSet: '$location.city' },
      first_seen: { $min: '$timestamp' },
      last_seen:  { $max: '$timestamp' }
  }},

  // Stage 3 - apply the fraud rule
  { $match: {
      attempts:   { $gte: 3 },
      'cities.1': { $exists: true }        // array has a 2nd element
  }},

  // Stage 4 - shape the output for the compliance team
  { $project: {
      _id: 0,
      customer_id: '$_id.customer',
      hour:        '$_id.hour',
      failed_attempts: '$attempts',
      distinct_cities: '$cities',
      window: { first_seen: '$first_seen', last_seen: '$last_seen' }
  }},

  { $sort: { customer_id: 1 } }
]).toArray();

// ---- Report ----
print('FLAGGED CUSTOMERS: ' + results.length + '\n');
results.forEach(r => {
  print('customer_id:      ' + r.customer_id);
  print('hour:             ' + r.hour.toISOString());
  print('failed_attempts:  ' + r.failed_attempts);
  print('distinct_cities:  ' + r.distinct_cities.join(', '));
  print('window:           ' + r.window.first_seen.toISOString() +
        '  ->  ' + r.window.last_seen.toISOString());
  print('------------------------------------------------------------');
});

// ---- Explanatory note (printed into the evidence file) ----
print('\nNOTE: Customers 9001-9006 were planted by seed_events.js');
print('(4 failed logins each, 4 distinct cities, within one hour),');
print('so a correct aggregation MUST flag exactly these 6 customers.');
print('No other customer crosses the >=3 attempts / >=2 cities rule.');
