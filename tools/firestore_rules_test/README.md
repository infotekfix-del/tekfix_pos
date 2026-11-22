# Firestore rules tests

Runs `firebase/firestore.rules` in the local Firestore emulator (no live data).
Needs Java 17+ and Node. Run before every `firebase deploy --only firestore:rules`:

    cd tools/firestore_rules_test
    npm install
    npm test

Expected: `25 passed, 0 failed`.
