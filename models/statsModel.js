const mongoose = require('mongoose')
const statsSchema = new mongoose.Schema({
    workWins: Number,
    altarWins: Number,
    deaths: Number,
    currentStreak: Number,
    highestStreak: Number,
})

module.exports = mongoose.model('End Stats Info', statsSchema)
