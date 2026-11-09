//! The catalog's list without its screen or the network: the pages adding up and the finger.
use starling_catalog::browser::{Kind, Project, SourceId};
use starling_catalog::list::{
    friendly, near_end, rows_shown, shown_part, Feed, Scroller, Tail, PAGE, SLOP,
};

fn project(id: &str) -> Project {
    Project {
        source: SourceId::Modrinth,
        id: id.into(),
        slug: id.into(),
        title: id.into(),
        summary: String::new(),
        author: String::new(),
        downloads: 0,
        page: String::new(),
        icon: None,
        license: String::new(),
        kind: Kind::ResourcePack,
        game_versions: Vec::new(),
        loaders: Vec::new(),
    }
}

/// Projects `from..to` as a page.
fn page(from: usize, to: usize) -> Result<Vec<Project>, String> {
    Ok((from..to).map(|i| project(&i.to_string())).collect())
}

fn ids(feed: &Feed) -> Vec<String> {
    feed.rows().iter().map(|p| p.id.clone()).collect()
}

fn first_of(ids: std::ops::Range<usize>) -> Vec<String> {
    ids.map(|i| i.to_string()).collect()
}

#[test]
fn each_page_adds_to_the_list_and_the_next_starts_after_it() {
    let mut feed = Feed::default();
    let first = feed.restart();
    assert_eq!(first.offset, 0);
    feed.answer(first, page(0, PAGE));
    assert_eq!(feed.tail(), &Tail::More);
    let second = feed.next().unwrap();
    assert_eq!(second.offset, PAGE);
    feed.answer(second, page(PAGE, PAGE * 2));
    assert_eq!(ids(&feed), first_of(0..PAGE * 2));
    assert_eq!(feed.next().unwrap().offset, PAGE * 2);
}

#[test]
fn only_one_page_is_on_its_way_at_a_time() {
    let mut feed = Feed::default();
    let first = feed.restart();
    assert_eq!(feed.next(), None, "the first page hasn't come");
    feed.answer(first, page(0, PAGE));
    let second = feed.next().unwrap();
    assert_eq!(feed.next(), None, "the second hasn't");
    // The same answer twice adds once.
    feed.answer(second, page(PAGE, PAGE * 2));
    feed.answer(second, page(PAGE, PAGE * 2));
    assert_eq!(feed.rows().len(), PAGE * 2);
}

#[test]
fn a_new_search_starts_over_and_an_old_answer_is_dropped() {
    let mut feed = Feed::default();
    let first = feed.restart();
    feed.answer(first, page(0, PAGE));
    let late = feed.next().unwrap();
    let new = feed.restart();
    assert!(feed.rows().is_empty());
    assert_eq!(new.offset, 0);
    feed.answer(late, page(PAGE, PAGE * 2));
    assert!(feed.rows().is_empty(), "the old search's page came late");
    assert_eq!(feed.tail(), &Tail::Loading);
    feed.answer(new, page(500, 503));
    assert_eq!(ids(&feed), ["500", "501", "502"]);
}

#[test]
fn a_short_page_isnt_the_end_and_an_empty_one_is() {
    let mut feed = Feed::default();
    let first = feed.restart();
    feed.answer(first, page(0, 3));
    let next = feed.next().expect("a short page may have lost rows");
    assert_eq!(next.offset, PAGE, "the source's offset, not the rows'");
    feed.answer(next, page(0, 0));
    assert_eq!(feed.tail(), &Tail::End);
    assert_eq!(feed.next(), None);
    assert_eq!(feed.rows().len(), 3);
}

#[test]
fn a_row_seen_on_an_earlier_page_is_left_out_and_the_pages_go_on() {
    let mut feed = Feed::default();
    let first = feed.restart();
    feed.answer(first, page(0, PAGE));
    let second = feed.next().unwrap();
    feed.answer(second, page(PAGE - 1, PAGE + 1));
    assert_eq!(ids(&feed), first_of(0..PAGE + 1));
    // A page of nothing but repeats isn't the end either.
    let third = feed.next().unwrap();
    assert_eq!(third.offset, PAGE * 2);
    feed.answer(third, page(0, PAGE));
    assert_eq!(feed.tail(), &Tail::More);
    assert_eq!(feed.next().unwrap().offset, PAGE * 3);
}

#[test]
fn a_failed_page_keeps_the_rows_and_waits_for_the_player() {
    let mut feed = Feed::default();
    let first = feed.restart();
    assert_eq!(feed.retry(), None, "nothing failed");
    feed.answer(first, page(0, PAGE));
    let second = feed.next().unwrap();
    feed.answer(second, Err("no network".into()));
    assert_eq!(feed.tail(), &Tail::Failed("no network".into()));
    assert_eq!(feed.rows().len(), PAGE);
    assert_eq!(feed.next(), None, "scrolling doesn't ask again");
    let again = feed.retry().unwrap();
    assert_eq!(again.offset, PAGE);
    feed.answer(again, page(PAGE, PAGE + 1));
    assert_eq!(feed.rows().len(), PAGE + 1);
}

const MOST: f32 = 1000.0;

/// A list a finger has dragged down to `offset`.
fn scrolled_to(offset: f32) -> Scroller {
    let mut list = Scroller::default();
    list.press(9, [0.0, 4000.0], true);
    list.moved(9, [0.0, 3000.0], MOST);
    list.moved(9, [0.0, 3000.0 - offset], MOST);
    assert_eq!(list.lift(9, [0.0, 3000.0 - offset], MOST), None);
    assert_eq!(list.offset, offset);
    list
}

#[test]
fn a_tap_without_moving_is_a_tap_where_it_came_down() {
    let mut list = Scroller::default();
    list.press(1, [100.0, 300.0], true);
    assert_eq!(list.lift(1, [100.0, 300.0], MOST), Some([100.0, 300.0]));
    assert_eq!(list.offset, 0.0);
}

#[test]
fn a_shaky_tap_is_still_a_tap() {
    let mut list = Scroller::default();
    list.press(1, [100.0, 300.0], true);
    list.moved(1, [103.0, 303.0], MOST);
    assert_eq!(list.lift(1, [102.0, 298.0], MOST), Some([100.0, 300.0]));
    assert_eq!(list.offset, 0.0, "the list stays until the finger drags");
}

#[test]
fn a_drag_moves_the_list_with_the_finger_and_presses_nothing() {
    let mut list = scrolled_to(50.0);
    list.press(1, [100.0, 300.0], true);
    // Past the slop the list takes hold there, without a jump.
    list.moved(1, [100.0, 300.0 - SLOP], MOST);
    assert_eq!(list.offset, 50.0);
    // Finger up, list further down.
    list.moved(1, [100.0, 300.0 - SLOP - 80.0], MOST);
    assert_eq!(list.offset, 130.0);
    // Back to where it came down: still a drag.
    list.moved(1, [100.0, 300.0], MOST);
    assert_eq!(list.lift(1, [100.0, 300.0], MOST), None);
}

#[test]
fn a_swipe_sideways_presses_nothing_either() {
    let mut list = Scroller::default();
    list.press(1, [100.0, 300.0], true);
    list.moved(1, [100.0 + SLOP + 1.0, 300.0], MOST);
    assert_eq!(list.lift(1, [100.0, 300.0], MOST), None);
    assert_eq!(list.offset, 0.0);
}

#[test]
fn a_flick_too_fast_for_a_move_event_isnt_a_tap() {
    let mut list = Scroller::default();
    list.press(1, [100.0, 300.0], true);
    assert_eq!(list.lift(1, [100.0, 100.0], MOST), None);
}

#[test]
fn the_list_stops_at_its_ends() {
    let mut list = Scroller::default();
    list.press(1, [100.0, 300.0], true);
    list.moved(1, [100.0, 400.0], MOST);
    list.moved(1, [100.0, 500.0], MOST);
    assert_eq!(list.offset, 0.0, "above the top");
    list.moved(1, [100.0, -5000.0], MOST);
    assert_eq!(list.offset, MOST, "past the end");
    assert_eq!(list.lift(1, [100.0, -5000.0], MOST), None);
    // A list shorter than the screen doesn't move.
    list.reset();
    list.press(1, [100.0, 300.0], true);
    list.moved(1, [100.0, 100.0], -50.0);
    list.moved(1, [100.0, 0.0], -50.0);
    assert_eq!(list.offset, 0.0);
}

#[test]
fn a_finger_that_came_down_above_the_list_neither_scrolls_nor_taps_once_it_moved() {
    let mut list = Scroller::default();
    list.press(1, [100.0, 60.0], false);
    list.moved(1, [100.0, 400.0], MOST);
    assert_eq!(list.offset, 0.0);
    assert_eq!(list.lift(1, [100.0, 400.0], MOST), None);
    // Without moving, it presses what it came down on.
    list.press(2, [100.0, 60.0], false);
    assert_eq!(list.lift(2, [100.0, 60.0], MOST), Some([100.0, 60.0]));
}

#[test]
fn a_second_finger_does_nothing() {
    let mut list = Scroller::default();
    list.press(1, [100.0, 300.0], true);
    list.press(2, [500.0, 300.0], true);
    list.moved(2, [500.0, 100.0], MOST);
    assert_eq!(list.offset, 0.0);
    assert_eq!(list.lift(2, [500.0, 100.0], MOST), None);
    assert_eq!(list.lift(1, [100.0, 300.0], MOST), Some([100.0, 300.0]));
}

#[test]
fn a_finger_from_before_the_screen_opened_presses_nothing() {
    let mut list = Scroller::default();
    assert_eq!(list.lift(1, [100.0, 300.0], MOST), None);
}

#[test]
fn a_cancelled_finger_is_no_tap_and_a_new_one_works() {
    let mut list = Scroller::default();
    list.press(1, [100.0, 300.0], true);
    list.cancel(1);
    assert_eq!(list.lift(1, [100.0, 300.0], MOST), None);
    list.press(1, [100.0, 300.0], true);
    assert_eq!(list.lift(1, [100.0, 300.0], MOST), Some([100.0, 300.0]));
}

#[test]
fn a_new_search_under_the_finger_goes_back_to_the_top_and_the_lift_presses_nothing() {
    let mut list = scrolled_to(400.0);
    list.press(1, [100.0, 300.0], true);
    list.reset();
    assert_eq!(list.offset, 0.0);
    assert_eq!(list.lift(1, [100.0, 300.0], MOST), None);
}

#[test]
fn only_the_rows_that_show_are_drawn() {
    // 100 tall in a list 250 tall.
    assert_eq!(rows_shown(0.0, 250.0, 100.0, 40), 0..3);
    assert_eq!(rows_shown(120.0, 250.0, 100.0, 40), 1..4);
    assert_eq!(rows_shown(300.0, 200.0, 100.0, 40), 3..5);
    assert_eq!(rows_shown(0.0, 250.0, 100.0, 2), 0..2);
    assert_eq!(rows_shown(900.0, 250.0, 100.0, 2), 2..2);
}

#[test]
fn the_next_page_comes_near_the_end_not_before() {
    let (view, content, margin) = (400.0, 2000.0, 200.0);
    assert!(!near_end(0.0, view, content, margin));
    assert!(!near_end(1399.0, view, content, margin));
    assert!(near_end(1400.0, view, content, margin));
    assert!(near_end(1600.0, view, content, margin));
    // A list that doesn't fill the screen is at its end from the start.
    assert!(near_end(0.0, view, 300.0, margin));
}

#[test]
fn a_button_under_what_is_above_or_below_the_list_takes_no_touch() {
    let (top, bottom) = (150.0, 620.0);
    assert_eq!(
        shown_part([10.0, 200.0, 50.0, 80.0], top, bottom),
        Some([10.0, 200.0, 50.0, 80.0])
    );
    assert_eq!(
        shown_part([10.0, 110.0, 50.0, 80.0], top, bottom),
        Some([10.0, 150.0, 50.0, 40.0])
    );
    assert_eq!(
        shown_part([10.0, 600.0, 50.0, 80.0], top, bottom),
        Some([10.0, 600.0, 50.0, 20.0])
    );
    assert_eq!(shown_part([10.0, 60.0, 50.0, 80.0], top, bottom), None);
    assert_eq!(shown_part([10.0, 620.0, 50.0, 80.0], top, bottom), None);
}

#[test]
fn a_dead_network_is_one_plain_sentence_with_no_url_or_os_text() {
    for raw in [
        "No connection to Modrinth: https://api.modrinth.com/v2/search: Network Error: Software caused connection abort (os error 103)",
        "Modrinth: Network Error: timed out reading response",
        "Download interrupted: connection reset by peer",
    ] {
        let said = friendly(raw, "Something else.");
        assert_eq!(
            said,
            "Couldn't reach the catalog. Check your connection and try again."
        );
        assert!(!said.contains("http") && !said.contains("os error"));
    }
}

#[test]
fn a_technical_error_gets_the_fallback_and_a_plain_one_stays() {
    assert_eq!(
        friendly(
            "Modrinth: https://api.modrinth.com/x: status code 500",
            "Try again."
        ),
        "Try again."
    );
    assert_eq!(
        friendly(
            "C:/x/y.zip: Access is denied. (os error 5)",
            "Couldn't install it."
        ),
        "Couldn't install it."
    );
    let plain = "Foo needs other projects, which can't be installed from here.";
    assert_eq!(friendly(plain, "Try again."), plain);
}
