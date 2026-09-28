import Foundation
import Testing
@testable import Nostalgex

@Suite("Daily manifest scheduling")
struct DailyManifestTests {

    private func makeItem(id: String, title: String, minutes: Int, addedAt: Int = 0) -> PlexMediaItem {
        PlexMediaItem(
            id: id,
            title: title,
            artist: nil,
            episodeTitle: nil,
            seTag: nil,
            summary: "",
            year: 2000,
            originallyAvailableAt: nil,
            contentRating: nil,
            duration: minutes,
            ratingKey: id,
            partKey: nil,
            container: "mp4",
            videoCodec: nil,
            audioCodec: nil,
            videoProfile: nil,
            bitrate: nil,
            genres: [],
            rating: 0,
            userRating: 0,
            type: .movie,
            thumb: nil,
            art: nil,
            viewCount: 0,
            addedAt: addedAt,
            studio: nil,
            tmdbID: nil,
            imdbID: nil,
            librarySource: .movie
        )
    }

    @Test("Day two prefers items not aired on day one")
    func unplayedFirstNextDay() throws {
        let fp = "test-fingerprint"
        DailyManifestStore.clearAll(credentialFingerprint: fp)

        let pool = [
            makeItem(id: "1", title: "Alpha", minutes: 60),
            makeItem(id: "2", title: "Bravo", minutes: 60),
            makeItem(id: "3", title: "Charlie", minutes: 60),
            makeItem(id: "4", title: "Delta", minutes: 60),
        ]

        var channel = Channel(
            id: 7,
            number: 7,
            name: "Test",
            color: .blue,
            category: nil,
            rules: nil,
            timeRestrictions: nil,
            minItems: 1,
            itemPool: pool,
            enabled: true
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 5, day: 20, hour: 12))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 5, day: 21, hour: 12))!

        let day1Blocks = DailyManifestScheduler.blocks(
            for: channel,
            at: day1,
            credentialFingerprint: fp,
            calendar: calendar
        )
        #expect(!day1Blocks.isEmpty)

        let day1Keys = Set(day1Blocks.map { $0.item.id })
        let day2Blocks = DailyManifestScheduler.blocks(
            for: channel,
            at: day2,
            credentialFingerprint: fp,
            calendar: calendar
        )
        #expect(!day2Blocks.isEmpty)

        let day2FirstKeys = Set(day2Blocks.prefix(4).map { $0.item.id })
        let unplayedFromDay1 = Set(pool.map(\.id)).subtracting(day1Keys)
        if !unplayedFromDay1.isEmpty {
            #expect(day2FirstKeys.isSubset(of: unplayedFromDay1))
        }

        DailyManifestStore.clearAll(credentialFingerprint: fp)
    }

    // MARK: - No back-to-back repeat at the wraparound seam

    /// A small pool exhausts the day's primary pass in a couple of hours, so the
    /// wraparound fill (packDay's second pass) runs almost every day for a niche
    /// channel. The wraparound picks its starting point from a golden-ratio offset
    /// with no idea what the primary pass just played, and landing on that same
    /// title produced the exact bug seen on device: Toy Story, Cobra, Waterworld,
    /// Heavyweights and Dirty Dancing each aired twice in a row with zero gap.
    @Test("The wraparound fill never repeats the item that just finished")
    func noBackToBackRepeatAtWraparoundSeam() throws {
        let fp = "test-fingerprint-wraparound"
        DailyManifestStore.clearAll(credentialFingerprint: fp)

        // Three items, 40 minutes each: 120 minutes total against a 1440-minute day.
        // The primary pass burns through the pool in two hours, guaranteeing the
        // wraparound path runs for the other twenty-two.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        // Sweep pool sizes (real affected channels ranged from ~3 to ~8 titles) and many
        // channel ids and days. The golden-ratio offset landing on the item that just
        // finished is a coincidence, not a deterministic failure -- roughly 1-in-N odds
        // per day for an N-item pool -- so a single day or a single channel id is not
        // enough to reliably reproduce it; a broad sweep is.
        for poolSize in 2...8 {
            let pool = (0..<poolSize).map { makeItem(id: "item\($0)", title: "Title \($0)", minutes: 40) }
            for channelId in 1...20 {
                let channel = Channel(
                    id: channelId,
                    number: channelId,
                    name: "Small Pool Test",
                    color: .blue,
                    category: nil,
                    rules: nil,
                    timeRestrictions: nil,
                    minItems: 1,
                    itemPool: pool,
                    enabled: true
                )
                for day in 1...10 {
                    let date = calendar.date(from: DateComponents(year: 2026, month: 6, day: day, hour: 0))!
                    let blocks = DailyManifestScheduler.blocks(
                        for: channel, at: date, credentialFingerprint: "\(fp)-\(poolSize)-\(channelId)",
                        calendar: calendar
                    )
                    #expect(!blocks.isEmpty)
                    for i in 0..<(blocks.count - 1) {
                        #expect(
                            blocks[i].item.id != blocks[i + 1].item.id,
                            "pool=\(poolSize) channel=\(channelId) day=\(day): \"\(blocks[i].item.title)\" aired twice back to back at index \(i)"
                        )
                    }
                }
                DailyManifestStore.clearAll(credentialFingerprint: "\(fp)-\(poolSize)-\(channelId)")
            }
        }
    }


    private func realMINIONHQPool() -> [PlexMediaItem] {
        [
            makeItem(id: "2393", title: "Despicable Me", minutes: 95),
            makeItem(id: "2394", title: "Despicable Me 2", minutes: 98),
            makeItem(id: "47158", title: "Despicable Me 3", minutes: 90),
            makeItem(id: "44610", title: "The Grinch", minutes: 86),
            makeItem(id: "8394", title: "The Lorax", minutes: 86),
            makeItem(id: "47451", title: "Midnight Mission", minutes: 5),
            makeItem(id: "5524", title: "Minions", minutes: 86),
            makeItem(id: "46243", title: "The Secret Life of Pets", minutes: 86),
            makeItem(id: "7080", title: "Sing", minutes: 108),
            makeItem(id: "43272", title: "Sing 2", minutes: 110),
            makeItem(id: "47445", title: "Sing: Thriller", minutes: 11),
            makeItem(id: "41015", title: "The Super Mario Galaxy Movie", minutes: 101),
        ]
    }

    private func realBUDDIESPool() -> [PlexMediaItem] {
        [
            makeItem(id: "47383", title: "2 Fast 2 Furious", minutes: 108),
            makeItem(id: "20008", title: "13 Going on 30", minutes: 98),
            makeItem(id: "517", title: "Ace Ventura: Pet Detective", minutes: 86),
            makeItem(id: "518", title: "Ace Ventura: When Nature Calls", minutes: 94),
            makeItem(id: "578", title: "Air Force One", minutes: 125),
            makeItem(id: "603", title: "Airheads", minutes: 92),
            makeItem(id: "656", title: "Alien³", minutes: 145),
            makeItem(id: "662", title: "Aliens", minutes: 154),
            makeItem(id: "47326", title: "Anchorman: The Legend of Ron Burgundy", minutes: 220),
            makeItem(id: "976", title: "Armageddon", minutes: 151),
            makeItem(id: "37324", title: "The Art of War", minutes: 117),
            makeItem(id: "1008", title: "Assassins", minutes: 133),
            makeItem(id: "47295", title: "Austin Powers in Goldmember", minutes: 88),
            makeItem(id: "1027", title: "Austin Powers: International Man of Mystery", minutes: 90),
            makeItem(id: "1028", title: "Austin Powers: The Spy Who Shagged Me", minutes: 95),
            makeItem(id: "1138", title: "Back to the Future", minutes: 111),
            makeItem(id: "1140", title: "Back to the Future Part II", minutes: 104),
            makeItem(id: "1145", title: "Bad Boys", minutes: 119),
            makeItem(id: "1153", title: "Bad Boys II", minutes: 147),
            makeItem(id: "44827", title: "Barbershop", minutes: 102),
            makeItem(id: "44937", title: "Barbershop 2: Back in Business", minutes: 106),
            makeItem(id: "1342", title: "Big Daddy", minutes: 93),
            makeItem(id: "35159", title: "Big Momma's House", minutes: 99),
            makeItem(id: "1358", title: "Billy Madison", minutes: 90),
            makeItem(id: "44632", title: "Black Sheep", minutes: 86),
            makeItem(id: "45311", title: "Blade: Trinity", minutes: 122),
            makeItem(id: "7789", title: "The Bourne Identity", minutes: 118),
            makeItem(id: "7821", title: "The Bourne Supremacy", minutes: 109),
            makeItem(id: "1583", title: "Boys and Girls", minutes: 93),
            makeItem(id: "33364", title: "The Breakfast Club", minutes: 97),
            makeItem(id: "47268", title: "Broken Arrow", minutes: 108),
            makeItem(id: "1702", title: "Bruce Almighty", minutes: 101),
            makeItem(id: "41935", title: "Bulletproof", minutes: 84),
            makeItem(id: "41937", title: "Caddyshack", minutes: 98),
            makeItem(id: "1990", title: "Chances Are", minutes: 108),
            makeItem(id: "5732", title: "Christmas Vacation", minutes: 97),
            makeItem(id: "2060", title: "Cliffhanger", minutes: 113),
            makeItem(id: "47203", title: "Cobra", minutes: 87),
            makeItem(id: "34215", title: "Collateral Damage", minutes: 109),
            makeItem(id: "2121", title: "Con Air", minutes: 115),
            makeItem(id: "32323", title: "Congo", minutes: 108),
            makeItem(id: "2189", title: "Coyote Ugly", minutes: 101),
            makeItem(id: "2215", title: "Cradle 2 the Grave", minutes: 101),
            makeItem(id: "2311", title: "Dante's Peak", minutes: 109),
            makeItem(id: "2312", title: "Daredevil", minutes: 142),
            makeItem(id: "20121", title: "The Day After Tomorrow", minutes: 124),
            makeItem(id: "2335", title: "Daylight", minutes: 114),
            makeItem(id: "2336", title: "Days of Thunder", minutes: 107),
            makeItem(id: "2337", title: "Dazed and Confused", minutes: 102),
            makeItem(id: "2347", title: "Dead Poets Society", minutes: 130),
            makeItem(id: "29666", title: "Die Another Day", minutes: 133),
            makeItem(id: "2433", title: "Die Hard", minutes: 127),
            makeItem(id: "2437", title: "Die Hard 2", minutes: 118),
            makeItem(id: "2434", title: "Die Hard with a Vengeance", minutes: 123),
            makeItem(id: "38894", title: "Dodgeball: A True Underdog Story", minutes: 92),
            makeItem(id: "44687", title: "Down to Earth", minutes: 87),
            makeItem(id: "2607", title: "DragonHeart", minutes: 99),
            makeItem(id: "39641", title: "Dreamship Surprise: Period 1", minutes: 87),
            makeItem(id: "19805", title: "Driven", minutes: 117),
            makeItem(id: "2670", title: "Drop Zone", minutes: 102),
            makeItem(id: "2688", title: "Dude, Where's My Car?", minutes: 83),
            makeItem(id: "2690", title: "Dumb and Dumber", minutes: 113),
            makeItem(id: "47138", title: "Easy", minutes: 92),
            makeItem(id: "39911", title: "The Edge", minutes: 118),
            makeItem(id: "2907", title: "Enemy of the State", minutes: 132),
            makeItem(id: "42129", title: "Entrapment", minutes: 113),
            makeItem(id: "45102", title: "Eraser", minutes: 115),
            makeItem(id: "2948", title: "EuroTrip", minutes: 92),
            makeItem(id: "2971", title: "Executive Decision", minutes: 127),
            makeItem(id: "42133", title: "Exit Wounds", minutes: 101),
            makeItem(id: "3002", title: "Face/Off", minutes: 139),
            makeItem(id: "8046", title: "The Fast and the Furious", minutes: 107),
            makeItem(id: "33446", title: "Ferris Bueller's Day Off", minutes: 103),
            makeItem(id: "47115", title: "First Blood", minutes: 89),
            makeItem(id: "3198", title: "Flight of the Phoenix", minutes: 113),
            makeItem(id: "19211", title: "Forrest Gump", minutes: 142),
            makeItem(id: "3299", title: "Friday Night Lights", minutes: 118),
            makeItem(id: "3391", title: "G.I. Jane", minutes: 125),
            makeItem(id: "3522", title: "Gladiator", minutes: 171),
            makeItem(id: "3524", title: "Godzilla", minutes: 139),
            makeItem(id: "29736", title: "GoldenEye", minutes: 130),
            makeItem(id: "3558", title: "Gone in 60 Seconds", minutes: 118),
            makeItem(id: "3578", title: "Good Morning, Vietnam", minutes: 121),
            makeItem(id: "8146", title: "The Goonies", minutes: 114),
            makeItem(id: "34170", title: "The Great Outdoors", minutes: 90),
            makeItem(id: "3671", title: "Half Baked", minutes: 79),
            makeItem(id: "3721", title: "Happy Gilmore", minutes: 92),
            makeItem(id: "38885", title: "Harold & Kumar Go to White Castle", minutes: 84),
            makeItem(id: "3763", title: "Heartbreakers", minutes: 123),
            makeItem(id: "19857", title: "Heat", minutes: 170),
            makeItem(id: "3856", title: "Hook", minutes: 142),
            makeItem(id: "3926", title: "How High", minutes: 93),
            makeItem(id: "8191", title: "The Hunt for Red October", minutes: 135),
            makeItem(id: "8192", title: "The Hunted", minutes: 94),
            makeItem(id: "8208", title: "The Incredibles", minutes: 115),
            makeItem(id: "19129", title: "Independence Day", minutes: 154),
            makeItem(id: "33837", title: "Iron Will", minutes: 109),
            makeItem(id: "8213", title: "The Italian Job", minutes: 111),
            makeItem(id: "4469", title: "Jerry Maguire", minutes: 139),
            makeItem(id: "40851", title: "Joe Dirt", minutes: 91),
            makeItem(id: "46923", title: "Judge Dredd", minutes: 96),
            makeItem(id: "46012", title: "Jurassic Park III", minutes: 93),
            makeItem(id: "41503", title: "A Knight's Tale", minutes: 132),
            makeItem(id: "4909", title: "Ladder 49", minutes: 115),
            makeItem(id: "32210", title: "Lara Croft: Tomb Raider", minutes: 101),
            makeItem(id: "32157", title: "Lara Croft: Tomb Raider - The Cradle of Life", minutes: 118),
            makeItem(id: "8306", title: "The Last Boy Scout", minutes: 105),
            makeItem(id: "43845", title: "The Last Castle", minutes: 131),
            makeItem(id: "46374", title: "The Last of the Mohicans", minutes: 115),
            makeItem(id: "8324", title: "The Last Samurai", minutes: 154),
            makeItem(id: "42813", title: "Lethal Weapon", minutes: 110),
            makeItem(id: "44653", title: "Lethal Weapon 2", minutes: 114),
            makeItem(id: "44807", title: "Lethal Weapon 3", minutes: 118),
            makeItem(id: "42820", title: "Lethal Weapon 4", minutes: 127),
            makeItem(id: "5060", title: "Liar Liar", minutes: 86),
            makeItem(id: "19873", title: "Little Nicky", minutes: 90),
            makeItem(id: "45131", title: "The Long Kiss Goodnight", minutes: 121),
            makeItem(id: "44634", title: "The Lord of the Rings: The Fellowship of the Ring", minutes: 228),
            makeItem(id: "43930", title: "The Lord of the Rings: The Return of the King", minutes: 263),
            makeItem(id: "44662", title: "The Lord of the Rings: The Two Towers", minutes: 235),
            makeItem(id: "8419", title: "The Lost World: Jurassic Park", minutes: 123),
            makeItem(id: "39431", title: "Major League", minutes: 107),
            makeItem(id: "39630", title: "Major League II", minutes: 105),
            makeItem(id: "39433", title: "Major League: Back to the Minors", minutes: 100),
            makeItem(id: "5327", title: "Man on Fire", minutes: 146),
            makeItem(id: "5328", title: "Man on the Moon", minutes: 118),
            makeItem(id: "43958", title: "The Mask", minutes: 101),
            makeItem(id: "8531", title: "The Matrix", minutes: 136),
            makeItem(id: "8550", title: "The Matrix Reloaded", minutes: 138),
            makeItem(id: "8552", title: "The Matrix Revolutions", minutes: 129),
            makeItem(id: "44527", title: "Maximum Risk", minutes: 101),
            makeItem(id: "5415", title: "Me, Myself & Irene", minutes: 117),
            makeItem(id: "5420", title: "Men in Black", minutes: 98),
            makeItem(id: "5432", title: "Men in Black II", minutes: 84),
            makeItem(id: "20375", title: "Mission: Impossible", minutes: 110),
            makeItem(id: "5599", title: "Mission: Impossible II", minutes: 124),
            makeItem(id: "47682", title: "Money Talks", minutes: 96),
            makeItem(id: "34168", title: "Moonwalker", minutes: 93),
            makeItem(id: "5695", title: "Mrs. Doubtfire", minutes: 125),
            makeItem(id: "19869", title: "The Mummy", minutes: 125),
            makeItem(id: "33797", title: "The Mummy Returns", minutes: 130),
            makeItem(id: "47468", title: "The Muppet Christmas Carol", minutes: 86),
            makeItem(id: "37340", title: "Mystery Men", minutes: 121),
            makeItem(id: "39435", title: "The Naked Gun: From the Files of Police Squad!", minutes: 85),
            makeItem(id: "46710", title: "Napoleon Dynamite", minutes: 95),
            makeItem(id: "33417", title: "National Lampoon's European Vacation", minutes: 94),
            makeItem(id: "33416", title: "National Lampoon's Vacation", minutes: 98),
            makeItem(id: "5734", title: "National Security", minutes: 88),
            makeItem(id: "33824", title: "National Treasure", minutes: 131),
            makeItem(id: "45813", title: "Now and Then", minutes: 102),
            makeItem(id: "34172", title: "O Brother, Where Art Thou?", minutes: 108),
            makeItem(id: "5901", title: "Old School", minutes: 91),
            makeItem(id: "20632", title: "Orange County", minutes: 82),
            makeItem(id: "6002", title: "Out Cold", minutes: 90),
            makeItem(id: "19802", title: "Over the Top", minutes: 94),
            makeItem(id: "6103", title: "Patch Adams", minutes: 115),
            makeItem(id: "43981", title: "The Peacemaker", minutes: 124),
            makeItem(id: "39473", title: "The Perfect Score", minutes: 93),
            makeItem(id: "35190", title: "The Perfect Storm", minutes: 130),
            makeItem(id: "8665", title: "The Pest", minutes: 84),
            makeItem(id: "6157", title: "Pirates of the Caribbean: The Curse of the Black Pearl", minutes: 143),
            makeItem(id: "39498", title: "Planes, Trains & Automobiles", minutes: 87),
            makeItem(id: "48732", title: "Point Break", minutes: 122),
            makeItem(id: "41096", title: "Pokémon the Movie 2000", minutes: 81),
            makeItem(id: "45910", title: "Pulp Fiction", minutes: 155),
            makeItem(id: "6324", title: "Rambo III", minutes: 97),
            makeItem(id: "6307", title: "Rambo: First Blood Part II", minutes: 92),
            makeItem(id: "45019", title: "Ready to Rumble", minutes: 106),
            makeItem(id: "8777", title: "The Recruit", minutes: 115),
            makeItem(id: "43170", title: "Reindeer Games", minutes: 125),
            makeItem(id: "45029", title: "The Replacement Killers", minutes: 96),
            makeItem(id: "8817", title: "The River Wild", minutes: 111),
            makeItem(id: "6578", title: "Road House", minutes: 114),
            makeItem(id: "46552", title: "Road Trip", minutes: 94),
            makeItem(id: "6598", title: "Robin Hood: Prince of Thieves", minutes: 138),
            makeItem(id: "8819", title: "The Rock", minutes: 137),
            makeItem(id: "6671", title: "Romeo Must Die", minutes: 115),
            makeItem(id: "37140", title: "Romy and Michele's High School Reunion", minutes: 92),
            makeItem(id: "6672", title: "Ronin", minutes: 121),
            makeItem(id: "44839", title: "Rumble in the Bronx", minutes: 90),
            makeItem(id: "8865", title: "The Rundown", minutes: 104),
            makeItem(id: "44400", title: "Rush Hour", minutes: 98),
            makeItem(id: "44602", title: "Rush Hour 2", minutes: 90),
            makeItem(id: "8898", title: "The Santa Clause 2", minutes: 104),
            makeItem(id: "48561", title: "Saved by the Bell: Hawaiian Style", minutes: 94),
            makeItem(id: "40009", title: "Scarface", minutes: 170),
            makeItem(id: "47584", title: "Scary Movie", minutes: 88),
            makeItem(id: "47582", title: "Scary Movie 3", minutes: 76),
            makeItem(id: "44810", title: "School of Rock", minutes: 109),
            makeItem(id: "19733", title: "Scooby-Doo", minutes: 87),
            makeItem(id: "33795", title: "The Scorpion King", minutes: 91),
            makeItem(id: "44555", title: "Shanghai Noon", minutes: 110),
            makeItem(id: "44559", title: "The Sixth Man", minutes: 108),
            makeItem(id: "35280", title: "Snatch", minutes: 103),
            makeItem(id: "34490", title: "Soldier", minutes: 99),
            makeItem(id: "9092", title: "The Specialist", minutes: 105),
            makeItem(id: "7230", title: "Speed", minutes: 116),
            makeItem(id: "19125", title: "Spider-Man", minutes: 121),
            makeItem(id: "38766", title: "Splash", minutes: 110),
            makeItem(id: "20575", title: "Spy Game", minutes: 127),
            makeItem(id: "7318", title: "Star Wars: Episode I - The Phantom Menace", minutes: 136),
            makeItem(id: "7319", title: "Star Wars: Episode II - Attack of the Clones", minutes: 142),
            makeItem(id: "8013", title: "Star Wars: Episode V - The Empire Strikes Back", minutes: 127),
            makeItem(id: "6505", title: "Star Wars: Episode VI - Return of the Jedi", minutes: 135),
            makeItem(id: "44557", title: "Sudden Death", minutes: 110),
            makeItem(id: "40858", title: "Super Troopers", minutes: 100),
            makeItem(id: "46454", title: "Swingers", minutes: 96),
            makeItem(id: "47422", title: "Swordfish", minutes: 99),
            makeItem(id: "46438", title: "Tarzan", minutes: 92),
            makeItem(id: "29636", title: "Teenage Mutant Ninja Turtles", minutes: 94),
            makeItem(id: "25333", title: "Teenage Mutant Ninja Turtles III", minutes: 96),
            makeItem(id: "46208", title: "The Terminator", minutes: 107),
            makeItem(id: "7574", title: "Terminator 2: Judgment Day", minutes: 153),
            makeItem(id: "7585", title: "Terminator 3: Rise of the Machines", minutes: 109),
            makeItem(id: "46156", title: "Three Kings", minutes: 115),
            makeItem(id: "45803", title: "Tin Cup", minutes: 135),
            makeItem(id: "44721", title: "Tommy Boy", minutes: 97),
            makeItem(id: "29671", title: "Tomorrow Never Dies", minutes: 120),
            makeItem(id: "9434", title: "Top Gun", minutes: 110),
            makeItem(id: "9436", title: "Total Recall", minutes: 108),
            makeItem(id: "9168", title: "The Transporter", minutes: 92),
            makeItem(id: "37930", title: "Treasure Planet", minutes: 95),
            makeItem(id: "45997", title: "Troy", minutes: 196),
            makeItem(id: "44273", title: "True Lies", minutes: 141),
            makeItem(id: "19124", title: "The Truman Show", minutes: 103),
            makeItem(id: "46003", title: "Twister", minutes: 113),
            makeItem(id: "38879", title: "U-571", minutes: 108),
            makeItem(id: "9754", title: "U.S. Marshals", minutes: 131),
            makeItem(id: "39494", title: "Uncle Buck", minutes: 100),
            makeItem(id: "9787", title: "Under Siege", minutes: 103),
            makeItem(id: "46147", title: "Under Siege 2: Dark Territory", minutes: 100),
            makeItem(id: "46136", title: "Uptown Girls", minutes: 92),
            makeItem(id: "9885", title: "Varsity Blues", minutes: 105),
            makeItem(id: "9886", title: "Vegas Vacation", minutes: 95),
            makeItem(id: "40960", title: "Vertical Limit", minutes: 125),
            makeItem(id: "9904", title: "Volcano", minutes: 100),
            makeItem(id: "46119", title: "Walking Tall", minutes: 86),
            makeItem(id: "9235", title: "The Waterboy", minutes: 86),
            makeItem(id: "10008", title: "Waterworld", minutes: 130),
            makeItem(id: "10009", title: "Wayne's World", minutes: 94),
            makeItem(id: "10010", title: "Wayne's World 2", minutes: 95),
            makeItem(id: "10109", title: "While You Were Sleeping", minutes: 103),
            makeItem(id: "10139", title: "White Chicks", minutes: 110),
            makeItem(id: "44315", title: "Wild America", minutes: 106),
            makeItem(id: "10152", title: "Wildcats", minutes: 106),
            makeItem(id: "10157", title: "Without a Paddle", minutes: 99),
            makeItem(id: "29722", title: "The World Is Not Enough", minutes: 128),
            makeItem(id: "21830", title: "X-Men", minutes: 104),
            makeItem(id: "22855", title: "X2: X-Men United", minutes: 134),
        ]
    }

    private func realDIZNEYTOONSPool() -> [PlexMediaItem] {
        [
            makeItem(id: "604", title: "Aladdin", minutes: 90),
            makeItem(id: "7683", title: "The AristoCats", minutes: 76),
            makeItem(id: "1343", title: "Big Hero 6", minutes: 102),
            makeItem(id: "1545", title: "Bolt", minutes: 96),
            makeItem(id: "45857", title: "Chip 'n Dale: Rescue Rangers", minutes: 97),
            makeItem(id: "47536", title: "Dumbo", minutes: 64),
            makeItem(id: "47402", title: "The Emperor's New Groove", minutes: 79),
            makeItem(id: "47542", title: "An Extremely Goofy Movie", minutes: 75),
            makeItem(id: "8108", title: "The Fox and the Hound", minutes: 79),
            makeItem(id: "3772", title: "Hercules", minutes: 89),
            makeItem(id: "33776", title: "Home on the Range", minutes: 76),
            makeItem(id: "8185", title: "The Hunchback of Notre Dame", minutes: 87),
            makeItem(id: "46385", title: "The Jungle Book", minutes: 75),
            makeItem(id: "37365", title: "Kronk's New Groove", minutes: 72),
            makeItem(id: "46846", title: "Lilo & Stitch", minutes: 85),
            makeItem(id: "43890", title: "The Lion King", minutes: 118),
            makeItem(id: "47469", title: "The Lion King II: Simba's Pride", minutes: 81),
            makeItem(id: "5478", title: "Mickey, Donald, Goofy: The Three Musketeers", minutes: 68),
            makeItem(id: "5476", title: "Mickey's Christmas Carol", minutes: 26),
            makeItem(id: "19340", title: "Moana 2", minutes: 100),
            makeItem(id: "45950", title: "Mufasa: The Lion King", minutes: 118),
            makeItem(id: "46711", title: "Mulan", minutes: 88),
            makeItem(id: "5902", title: "Oliver & Company", minutes: 74),
            makeItem(id: "6143", title: "Pinocchio", minutes: 88),
            makeItem(id: "37290", title: "Pocahontas", minutes: 81),
            makeItem(id: "45047", title: "Ralph Breaks the Internet", minutes: 113),
            makeItem(id: "6582", title: "Robin Hood", minutes: 83),
            makeItem(id: "46478", title: "Sleeping Beauty", minutes: 75),
            makeItem(id: "10153", title: "Winnie the Pooh", minutes: 63),
            makeItem(id: "46083", title: "Wreck-It Ralph", minutes: 101),
            makeItem(id: "38923", title: "Zootopia 2", minutes: 108),
        ]
    }

    private func realPIXARMOVIESPool() -> [PlexMediaItem] {
        [
            makeItem(id: "1585", title: "Brave", minutes: 94),
            makeItem(id: "290", title: "A Bug's Life", minutes: 95),
            makeItem(id: "47257", title: "Cars", minutes: 117),
            makeItem(id: "47224", title: "Cars 2", minutes: 107),
            makeItem(id: "1904", title: "Cars 3", minutes: 102),
            makeItem(id: "2088", title: "Coco", minutes: 105),
            makeItem(id: "19473", title: "Elemental", minutes: 101),
            makeItem(id: "19718", title: "Elio", minutes: 98),
            makeItem(id: "3192", title: "Finding Dory", minutes: 97),
            makeItem(id: "3193", title: "Finding Nemo", minutes: 92),
            makeItem(id: "8144", title: "The Good Dinosaur", minutes: 93),
            makeItem(id: "40760", title: "Hoppers", minutes: 104),
            makeItem(id: "8208", title: "The Incredibles", minutes: 115),
            makeItem(id: "42631", title: "Incredibles 2", minutes: 118),
            makeItem(id: "4197", title: "Inside Out", minutes: 95),
            makeItem(id: "19358", title: "Inside Out 2", minutes: 96),
            makeItem(id: "25341", title: "Lightyear", minutes: 105),
            makeItem(id: "21526", title: "Luca", minutes: 95),
            makeItem(id: "5613", title: "Monsters University", minutes: 104),
            makeItem(id: "5614", title: "Monsters, Inc.", minutes: 92),
            makeItem(id: "6387", title: "Ratatouille", minutes: 111),
            makeItem(id: "9486", title: "Toy Story", minutes: 77),
            makeItem(id: "9487", title: "Toy Story 2", minutes: 92),
            makeItem(id: "9488", title: "Toy Story 3", minutes: 103),
            makeItem(id: "44725", title: "Toy Story 4", minutes: 100),
            makeItem(id: "48570", title: "Toy Story 5", minutes: 102),
            makeItem(id: "19456", title: "Turning Red", minutes: 100),
            makeItem(id: "9809", title: "Up", minutes: 97),
            makeItem(id: "9980", title: "WALL·E", minutes: 98),
        ]
    }

    // MARK: - No back-to-back repeat across the midnight boundary

    /// Same coincidence as the wraparound seam, one level up: `blocks(for:...)` computes
    /// one calendar day at a time with no memory of what the previous call scheduled, so
    /// whatever leads off today has no idea it might be exactly what closed out
    /// yesterday. Swept broadly for the same reason the wraparound sweep needed to be
    /// broad: the coincidence is roughly 1-in-N per day for an N-item pool, so a single
    /// channel id or a single day pair proves nothing on its own.
    @Test("The next day never opens with the item that just closed out the previous one")
    func noBackToBackRepeatAcrossMidnight() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let realPools: [(name: String, pool: [PlexMediaItem])] = [
            ("MINION HQ", realMINIONHQPool()),
            ("DIZNEY TOONS", realDIZNEYTOONSPool()),
            ("PIXAR MOVIES", realPIXARMOVIESPool()),
            ("BUDDIES", realBUDDIESPool()),
        ]

        var seamsChecked = 0
        for (name, pool) in realPools {
            for channelId in stride(from: 300, through: 360, by: 4) {
                let fp = "midnight-\(name)-\(channelId)"
                DailyManifestStore.clearAll(credentialFingerprint: fp)
                let channel = Channel(
                    id: channelId, number: channelId, name: name, color: .blue, category: nil,
                    rules: nil, timeRestrictions: nil, minItems: 1, itemPool: pool, enabled: true
                )

                var previousLastItem: PlexMediaItem?
                for day in 1...15 {
                    let date = calendar.date(from: DateComponents(year: 2026, month: 2, day: day, hour: 0))!
                    let blocks = DailyManifestScheduler.blocks(
                        for: channel, at: date, credentialFingerprint: fp, calendar: calendar
                    )
                    #expect(!blocks.isEmpty, "\(name) id=\(channelId) day \(day): produced no blocks at all")

                    if let previousLastItem, let first = blocks.first {
                        seamsChecked += 1
                        #expect(
                            previousLastItem.id != first.item.id,
                            "\(name) id=\(channelId): day \(day - 1) ended with \"\(previousLastItem.title)\" and day \(day) opened with it again"
                        )
                    }
                    previousLastItem = blocks.last?.item
                }
                DailyManifestStore.clearAll(credentialFingerprint: fp)
            }
        }
        #expect(seamsChecked > 0, "no day-to-day boundary was ever checked -- this sweep proves nothing")
    }

    // MARK: - Real library data, not synthetic

    /// Same check as the sweep above, against the actual pools that produced the reported
    /// bug on device (pulled from a real library snapshot 2026-09-10): MINION HQ (12 items,
    /// mixed feature-length and 5-11 minute shorts), DIZNEY TOONS (31), PIXAR MOVIES (29),
    /// and BUDDIES (249 -- large enough that the wraparound path should rarely trigger,
    /// which makes it the sharpest test of whether the fix generalizes or whether Cobra
    /// airing twice on BUDDIES was a separate issue).
    @Test("No back-to-back repeat across 30 real days, on the real reported pools")
    func noBackToBackRepeatOnRealPools() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let realPools: [(name: String, pool: [PlexMediaItem])] = [
            ("MINION HQ", realMINIONHQPool()),
            ("DIZNEY TOONS", realDIZNEYTOONSPool()),
            ("PIXAR MOVIES", realPIXARMOVIESPool()),
            ("BUDDIES", realBUDDIESPool()),
        ]

        // A single fixed channel id only samples one point in the golden-ratio offset
        // sequence. Vary it, same as the synthetic sweep above, so the odds of actually
        // exercising the coincidence are real rather than a matter of which id happened
        // to be picked. If BUDDIES (249 items, ~115 min average -- the primary pass alone
        // should almost never exhaust a day) genuinely never triggers this across the
        // sweep, that is real evidence its Cobra repeat on device has a different cause,
        // not proof by a single untested id.
        var crossDaySeamHits = 0
        var wraparoundDays = 0
        var totalDays = 0
        for (name, pool) in realPools {
            for channelId in stride(from: 200, through: 260, by: 4) {
                let fp = "real-pool-\(name)-\(channelId)"
                DailyManifestStore.clearAll(credentialFingerprint: fp)
                let channel = Channel(
                    id: channelId, number: channelId, name: name, color: .blue, category: nil,
                    rules: nil, timeRestrictions: nil, minItems: 1, itemPool: pool, enabled: true
                )

                var previousLastItem: PlexMediaItem?
                for day in 1...15 {
                    let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: day, hour: 0))!
                    let blocks = DailyManifestScheduler.blocks(
                        for: channel, at: date, credentialFingerprint: fp, calendar: calendar
                    )
                    #expect(!blocks.isEmpty, "\(name) id=\(channelId) day \(day): produced no blocks at all")

                    // Diagnostic, not an assertion: does this day even reach the wraparound
                    // path? A repeat ANYWHERE in the day (not just adjacent) proves a full
                    // lap of the pool completed within 24h, which is the only way the
                    // wraparound runs at all. If real pools never do this, the sweep is
                    // proving nothing either way.
                    var seen = Set<String>()
                    var lappedToday = false
                    for b in blocks {
                        if seen.contains(b.item.id) { lappedToday = true }
                        seen.insert(b.item.id)
                    }
                    if lappedToday { wraparoundDays += 1 }
                    totalDays += 1

                    for i in 0..<(blocks.count - 1) {
                        #expect(
                            blocks[i].item.id != blocks[i + 1].item.id,
                            "\(name) id=\(channelId) day \(day): \"\(blocks[i].item.title)\" aired twice back to back at index \(i)"
                        )
                    }

                    // Cross-day seam: the same coincidence could exist at midnight, between
                    // yesterday's last block and today's first -- a boundary the wraparound
                    // fix does not touch, since it only guards the seam *inside* one day's
                    // packDay call. Counted, not asserted on: it is a real open question,
                    // not yet a claimed fix.
                    if let previousLastItem, let first = blocks.first, previousLastItem.id == first.item.id {
                        crossDaySeamHits += 1
                    }
                    previousLastItem = blocks.last?.item
                }
                DailyManifestStore.clearAll(credentialFingerprint: fp)
            }
        }
        // Assertions instead of prints: print() output from swift-testing under xcodebuild
        // is unreliable to retrieve, assertion failures are not. This is the load-bearing
        // check -- if the wraparound path is never reached, every check above is vacuous
        // for these real pools regardless of what it reported.
        #expect(wraparoundDays > 0, "wraparound path was never reached across \(totalDays) channel-days -- this sweep proves nothing about these real pools")
        // Confirms the sweep actually exercises the vulnerable path (511 of 960
        // channel-days did, in the run that established this test), so a clean pass above
        // means something. Not asserting on crossDaySeamHits: that boundary (yesterday's
        // last block vs today's first, across two independent packDay calls) is a real,
        // separate, currently-unfixed gap -- 26 hits in that same run -- left for a
        // follow-up rather than silently asserted away here.
        #expect(wraparoundDays > 0, "wraparound path was never reached across \(totalDays) channel-days -- this sweep proves nothing about these real pools")
    }

    @Test("Schedule builder resolves now playing from manifest")
    func scheduleFromManifest() {
        let fp = "test-fingerprint-2"
        DailyManifestStore.clearAll(credentialFingerprint: fp)

        let pool = [
            makeItem(id: "a", title: "One", minutes: 30),
            makeItem(id: "b", title: "Two", minutes: 30),
        ]
        let channel = Channel(
            id: 3,
            number: 3,
            name: "Movies",
            color: .red,
            category: nil,
            rules: nil,
            timeRestrictions: nil,
            minItems: 1,
            itemPool: pool,
            enabled: true
        )

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let noon = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1, hour: 12))!

        let schedule = ChannelScheduleBuilder.buildSchedule(
            for: channel,
            at: noon,
            credentialFingerprint: fp
        )
        #expect(schedule != nil)
        #expect(schedule?.nowPlaying != nil)

        DailyManifestStore.clearAll(credentialFingerprint: fp)
    }

    // MARK: - In-memory memo
    //
    // `blocks(for:)` memoizes so SwiftUI bodies can call it per channel card without
    // re-hashing the pool and re-decoding the manifest every time. These cover the two
    // ways that memo could go wrong: serving a different lineup on a repeat call, or
    // serving a stale one after the underlying manifests are thrown away.

    private func makeChannel(id: Int, pool: [PlexMediaItem]) -> Channel {
        Channel(
            id: id,
            number: id,
            name: "Test \(id)",
            color: .blue,
            category: nil,
            rules: nil,
            timeRestrictions: nil,
            minItems: 1,
            itemPool: pool,
            enabled: true
        )
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test("Repeat calls return the same lineup")
    func memoIsStable() {
        let fp = "test-memo-stable"
        DailyManifestStore.clearAll(credentialFingerprint: fp)

        let channel = makeChannel(id: 11, pool: (0..<12).map {
            makeItem(id: "s\($0)", title: "Show \($0)", minutes: 45)
        })
        let calendar = utcCalendar
        let noon = calendar.date(from: DateComponents(year: 2026, month: 7, day: 4, hour: 12))!

        let first = DailyManifestScheduler.blocks(
            for: channel, at: noon, credentialFingerprint: fp, calendar: calendar
        )
        let second = DailyManifestScheduler.blocks(
            for: channel, at: noon, credentialFingerprint: fp, calendar: calendar
        )

        #expect(!first.isEmpty)
        #expect(first.map(\.item.id) == second.map(\.item.id))
        #expect(first.map(\.startTime) == second.map(\.startTime))

        DailyManifestStore.clearAll(credentialFingerprint: fp)
    }

    @Test("Wiping manifests drops the memo so a changed pool is picked up")
    func memoInvalidatesOnClear() {
        let fp = "test-memo-invalidate"
        DailyManifestStore.clearAll(credentialFingerprint: fp)

        let calendar = utcCalendar
        let noon = calendar.date(from: DateComponents(year: 2026, month: 7, day: 5, hour: 12))!

        let original = makeChannel(id: 12, pool: (0..<10).map {
            makeItem(id: "old\($0)", title: "Old \($0)", minutes: 60)
        })
        let before = DailyManifestScheduler.blocks(
            for: original, at: noon, credentialFingerprint: fp, calendar: calendar
        )
        #expect(!before.isEmpty)

        // Same pool shape (10 items, same first/last positions) but entirely new content —
        // the case a memo keyed on shape alone would get wrong.
        DailyManifestStore.clearAll(credentialFingerprint: fp)
        let refreshed = makeChannel(id: 12, pool: (0..<10).map {
            makeItem(id: "new\($0)", title: "New \($0)", minutes: 60)
        })
        let after = DailyManifestScheduler.blocks(
            for: refreshed, at: noon, credentialFingerprint: fp, calendar: calendar
        )

        #expect(!after.isEmpty)
        #expect(after.allSatisfy { $0.item.id.hasPrefix("new") })

        DailyManifestStore.clearAll(credentialFingerprint: fp)
    }

    @Test("Separate days keep separate lineups")
    func memoKeyedByDay() {
        let fp = "test-memo-days"
        DailyManifestStore.clearAll(credentialFingerprint: fp)

        let calendar = utcCalendar
        let channel = makeChannel(id: 13, pool: (0..<30).map {
            makeItem(id: "d\($0)", title: "Day item \($0)", minutes: 40)
        })
        let day1 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 6, hour: 12))!
        let day2 = calendar.date(from: DateComponents(year: 2026, month: 7, day: 7, hour: 12))!

        let first = DailyManifestScheduler.blocks(
            for: channel, at: day1, credentialFingerprint: fp, calendar: calendar
        )
        let second = DailyManifestScheduler.blocks(
            for: channel, at: day2, credentialFingerprint: fp, calendar: calendar
        )

        #expect(!first.isEmpty)
        #expect(!second.isEmpty)
        // Day two starts a day later — proof the memo did not hand back day one's blocks.
        #expect(second[0].startTime > first[0].startTime)

        DailyManifestStore.clearAll(credentialFingerprint: fp)
    }

    // MARK: - Premieres land on one channel only

    /// A freshly added film usually sits in several pools. Every channel used to promote
    /// it to the prime-time anchor, so it premiered on all of them at the same moment:
    /// Point Break, added to five channels, aired on five at once. Only the designated
    /// premiere channel promotes now; everywhere else the title keeps its rotation slot.
    @Test("A new addition is promoted only on the premiere channel")
    func recentAdditionPromotedOnlyOnPremiereChannel() {
        let dayStartUnix = 1_700_000_000
        var pool = (0..<30).map { makeItem(id: "old\($0)", title: "Old \($0)", minutes: 90) }
        pool.insert(
            makeItem(id: "fresh", title: "Point Break", minutes: 120, addedAt: dayStartUnix - 3600),
            at: 3
        )

        // The premiere channel moves it into the evening.
        let promoted = SchedulePoolOrdering.promoteRecentlyAdded(
            pool, dayStartUnix: dayStartUnix, channelId: 62
        )
        let promotedIndex = promoted.firstIndex { $0.id == "fresh" } ?? -1
        #expect(promotedIndex > 3)
        let promotedStart = promoted[0..<max(promotedIndex, 0)].reduce(0) { $0 + $1.duration * 60 }
        #expect(promotedStart >= SchedulePoolOrdering.premiereAnchorSeconds)

        // Every other channel skips promotion entirely, so the item keeps the slot the
        // interleave gave it — here index 3, hours before prime time.
        let untouchedIndex = pool.firstIndex { $0.id == "fresh" } ?? -1
        #expect(untouchedIndex == 3)
        let untouchedStart = pool[0..<max(untouchedIndex, 0)].reduce(0) { $0 + $1.duration * 60 }
        #expect(untouchedStart < SchedulePoolOrdering.premiereAnchorSeconds)
    }
}
