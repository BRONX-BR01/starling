fn iaf_dragon_net_from_server(game: &mut crate::game::Game<'_>, channel: &str, data: &[u8]) {
    crate::game::official_iaf_dragon_server::from_server(game, channel, data);
}
