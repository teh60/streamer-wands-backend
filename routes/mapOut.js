const express = require('express')
const router = express.Router()
const mongoose = require('mongoose')
const Streamer = mongoose.model('Streamers')

router.get('/', (req, res) => {
    Streamer.find(
        { "modFeatures.pos": true },
        {
            "_id": false,
            "name": true,
            "playerInfo.x": true,
            "playerInfo.y": true,
            // "progress": true
        })
        .lean()
        .then(users => {
            res.json(users.reduce((obj, user) => {
                const { name, ...info } = user
                return Object.assign(obj, { [name]: { ...info.playerInfo, ...info.progress } })
            }, {}))
        })
})

module.exports = router