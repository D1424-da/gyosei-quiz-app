// Firebase Configuration
// プロジェクト ID: chisatsu-exam-practice
const firebaseConfig = {
  apiKey: "AIzaSyALhMSjU_qObceADtp27EcjFVmRBrvZlFs",
  authDomain: "chisatsu-exam-practice.firebaseapp.com",
  projectId: "chisatsu-exam-practice",
  storageBucket: "chisatsu-exam-practice.firebasestorage.app",
  messagingSenderId: "487053227761",
  appId: "1:487053227761:web:12437a4c5dc89804791b50",
  measurementId: "G-W2X48FK30S"
};

// Optional app-level configuration.
// Googleログインを使う場合のみ Client ID を設定してください。
window.APP_CONFIG = {
  googleClientId: "",
  adminLoginEmail: "ikeda.job08@gmail.com",
  adminEmails: ["ikeda.job08@gmail.com"]
};

// Firebase を初期化（アプリ起動時に実行される）
if (!window.firebaseInitialized) {
  try {
    firebase.initializeApp(firebaseConfig);

    // WebChannel Listen 404/transport error が出る環境向けに
    // Firestore の接続方式を long-polling 優先へ寄せる。
    if (firebase.firestore) {
      firebase.firestore().settings({
        experimentalAutoDetectLongPolling: true,
        useFetchStreams: false,
        merge: true
      });
    }

    window.firebaseInitialized = true;
    console.log("✓ Firebase initialized");
  } catch (e) {
    console.error("✗ Firebase initialization error:", e);
  }
}

// グローバル参照（遅延初期化）
Object.defineProperty(window, 'auth', {
  get: function() {
    return firebase.auth ? firebase.auth() : null;
  }
});

Object.defineProperty(window, 'db', {
  get: function() {
    return firebase.firestore ? firebase.firestore() : null;
  }
});
