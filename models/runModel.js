const mongoose = require('mongoose')
const statsSchema = new mongoose.Schema({
    workWins: Number,
    altarWins: Number,
    deaths: Number,
    currentStreak: Number,
    highestStreak: Number,
    lowestStreak: Number,
})
const runSchema = new mongoose.Schema({
    mods: [String],
    beta: String,
    ngp: Number,
    seed: Number,
    start: Date,
    playtime: Number,
    idletime: Number,
    orbs: [Number],
    bosses: [String],
    endStats: statsSchema,
})

module.exports = mongoose.model('Run Info', runSchema)
