(function () {
	const firebaseConfig = {
		apiKey: "AIzaSyCqyybXHvlWBkDNRKaKpWc3K4S4S3e4gXg",
		authDomain: "gyosei-quiz-app-20260525.firebaseapp.com",
		projectId: "gyosei-quiz-app-20260525",
		storageBucket: "gyosei-quiz-app-20260525.firebasestorage.app",
		messagingSenderId: "38688280593",
		appId: "1:38688280593:web:20a0ee3f2de2399602e1b0"
	};

	if (window.firebase && typeof firebase.initializeApp === 'function') {
		try {
			if (!firebase.apps || !firebase.apps.length) {
				firebase.initializeApp(firebaseConfig);
			}
			// Firestore オフライン永続化を有効化（IndexedDB にキャッシュ）。
			// オフライン時もキャッシュから即座に読み込めるようになる。
			if (window.firebase && typeof firebase.firestore === 'function') {
				firebase.firestore().enablePersistence().catch((err) => {
					if (err.code === 'failed-precondition') {
						// 複数タブが同時に開いている場合、最初のタブのみ有効。
						console.info('Firestore オフライン永続化: 他のタブが開いているため無効化されました。');
					} else if (err.code === 'unimplemented') {
						// このブラウザはオフライン永続化非対応（Safari 古いバージョンなど）。
						console.info('Firestore オフライン永続化: このブラウザは非対応です。');
					}
				});
			}
		} catch (e) {
			console.error('Firebase initialization failed:', e);
		}
	}

	window.APP_CONFIG = {
		adminEmails: [
			"d.i.a.0101@gmail.com"
		],
		adminLogin: {
			username: "ikeda.job08@gmail.com",
			password: "admin1234"
		}
	};
})();
