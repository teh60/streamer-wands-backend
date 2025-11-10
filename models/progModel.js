const mongoose = require('mongoose')
const progSchema = new mongoose.Schema({
    perks: [String],
    spells: [String],
    uses: [Number],
    enemies: [String],
    kills: [Number],
})

module.exports = mongoose.model('Progress', progSchema)
