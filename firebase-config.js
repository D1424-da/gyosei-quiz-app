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
			if (firebase.firestore && typeof firebase.firestore === 'function') {
				firebase.firestore().settings({
					experimentalAutoDetectLongPolling: true,
					useFetchStreams: false,
					merge: true
				});
			}
			if (firebase.firestore && typeof firebase.firestore.setLogLevel === 'function') {
				firebase.firestore.setLogLevel('error');
			}
		} catch (e) {
			console.error('Firebase initialization failed:', e);
		}
	}

	window.APP_CONFIG = {
		adminEmails: [
			"d.i.a.0101@gmail.com"
		]
	};
})();
