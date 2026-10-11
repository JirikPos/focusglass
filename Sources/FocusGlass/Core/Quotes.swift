struct Quote: Hashable {
    let text: String
    let author: String
}

enum Quotes {
    static func random(excluding current: Quote? = nil) -> Quote {
        all.filter { $0 != current }.randomElement() ?? all[0]
    }

    static let all: [Quote] = [
        // David Goggins
        Quote(text: "You are in danger of living a life so comfortable and soft that you will die without ever realizing your true potential.", author: "David Goggins"),
        Quote(text: "Don't stop when you're tired. Stop when you're done.", author: "David Goggins"),
        Quote(text: "Motivation is crap. Motivation comes and goes.", author: "David Goggins"),
        Quote(text: "Be uncommon amongst uncommon people.", author: "David Goggins"),
        Quote(text: "Denial is the ultimate comfort zone.", author: "David Goggins"),
        Quote(text: "The most important conversations you'll ever have are the ones you'll have with yourself.", author: "David Goggins"),
        Quote(text: "Who's gonna carry the boats?", author: "David Goggins"),

        // Andrew Tate (citace kolující na internetu)
        Quote(text: "Your mind must be stronger than your feelings.", author: "Andrew Tate"),
        Quote(text: "The man who trains every day regardless of how he feels will always beat the man who trains when he feels like it.", author: "Andrew Tate"),

        // Podnikatelé a disciplína
        Quote(text: "Work like there is someone working 24 hours a day to take it all away from you.", author: "Mark Cuban"),
        Quote(text: "Be obsessed or be average.", author: "Grant Cardone"),
        Quote(text: "Stop whining, start hustling.", author: "Gary Vaynerchuk"),
        Quote(text: "Discipline equals freedom.", author: "Jocko Willink"),
        Quote(text: "Don't count on motivation. Count on discipline.", author: "Jocko Willink"),
        Quote(text: "We must all suffer one of two pains: the pain of discipline or the pain of regret.", author: "Jim Rohn"),
        Quote(text: "Discipline is doing what you hate to do, but doing it like you love it.", author: "Mike Tyson"),
        Quote(text: "Everyone has a plan until they get punched in the mouth.", author: "Mike Tyson"),
        Quote(text: "I hated every minute of training, but I said: don't quit. Suffer now and live the rest of your life as a champion.", author: "Muhammad Ali"),
        Quote(text: "Today I will do what others won't, so tomorrow I can do what others can't.", author: "Jerry Rice"),
        Quote(text: "Rest at the end, not in the middle.", author: "Kobe Bryant"),
        Quote(text: "The only easy day was yesterday.", author: "Navy SEALs"),

        // Bez obalu
        Quote(text: "Nobody is coming to save you.", author: "FocusGlass"),
        Quote(text: "You're not tired. You're undisciplined.", author: "FocusGlass"),
        Quote(text: "You said \"tomorrow\" yesterday.", author: "FocusGlass"),
        Quote(text: "Average is a choice. You keep making it.", author: "FocusGlass"),
        Quote(text: "Nobody cares how hard it is. Finish.", author: "FocusGlass"),
        Quote(text: "Comfort is a slow way to lose everything you could have built.", author: "FocusGlass"),
        Quote(text: "Every minute you waste, someone hungrier is building what you only talk about.", author: "FocusGlass"),
        Quote(text: "Your excuses are lying to you. Stop believing them.", author: "FocusGlass"),
        Quote(text: "Regret weighs more than discipline. Pick which one you carry.", author: "FocusGlass"),
        Quote(text: "Rest your eyes. Not your ambition.", author: "FocusGlass"),
        Quote(text: "One minute to recover. Then back to war.", author: "FocusGlass"),
    ]
}
