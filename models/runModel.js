const mongoose = require('mongoose')
const statsSchema = require('./statsModel').schema
const runSchema = new mongoose.Schema({
    mods: [String],
    beta: String,
    ngp: Number,
    seed: Number,
    start: Date,
    playtime: Number,
    idletime: Number,
    orbs: [Number],
    endStats: statsSchema,
})

module.exports = mongoose.model('Run Info', runSchema)
