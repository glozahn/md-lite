//! A container that keeps its child no wider than the text column (and an optional cap),
//! so embedded tables wrap and images shrink with the window.

use gtk::prelude::*;
use gtk::subclass::prelude::*;
use gtk::glib;
use std::cell::{Cell, RefCell};
use std::rc::Rc;

mod imp {
    use super::*;

    #[derive(Default)]
    pub struct Bounded {
        pub child: RefCell<Option<gtk::Widget>>,
        pub available: RefCell<Option<Rc<Cell<i32>>>>,
        pub cap: Cell<i32>,
    }

    #[glib::object_subclass]
    impl ObjectSubclass for Bounded {
        const NAME: &'static str = "MdBounded";
        type Type = super::Bounded;
        type ParentType = gtk::Widget;
    }

    impl ObjectImpl for Bounded {
        fn dispose(&self) {
            if let Some(child) = self.child.borrow_mut().take() {
                child.unparent();
            }
        }
    }

    impl WidgetImpl for Bounded {
        fn request_mode(&self) -> gtk::SizeRequestMode {
            gtk::SizeRequestMode::HeightForWidth
        }

        fn measure(&self, orientation: gtk::Orientation, for_size: i32) -> (i32, i32, i32, i32) {
            let Some(child) = self.child.borrow().clone() else { return (0, 0, -1, -1) };
            if orientation == gtk::Orientation::Horizontal {
                let (min, nat, _, _) = child.measure(orientation, for_size);
                let mut limit = self.available.borrow().as_ref().map_or(i32::MAX, |a| a.get());
                if self.cap.get() > 0 {
                    limit = limit.min(self.cap.get());
                }
                // GtkTextView gives anchored children their minimum size, so report the
                // width we want as the minimum.
                let width = nat.min(limit).max(min);
                (width, width, -1, -1)
            } else {
                let (min, nat, _, _) = child.measure(orientation, for_size);
                let height = nat.max(min);
                (height, height, -1, -1)
            }
        }

        fn size_allocate(&self, width: i32, height: i32, baseline: i32) {
            if let Some(child) = self.child.borrow().as_ref() {
                child.allocate(width, height, baseline, None);
            }
        }
    }
}

glib::wrapper! {
    pub struct Bounded(ObjectSubclass<imp::Bounded>)
        @extends gtk::Widget,
        @implements gtk::Accessible, gtk::Buildable, gtk::ConstraintTarget;
}

impl Bounded {
    pub fn new(child: &impl IsA<gtk::Widget>, available: Rc<Cell<i32>>, cap: i32) -> Bounded {
        let bounded: Bounded = glib::Object::new();
        child.set_parent(&bounded);
        *bounded.imp().child.borrow_mut() = Some(child.clone().upcast());
        *bounded.imp().available.borrow_mut() = Some(available);
        bounded.imp().cap.set(cap);
        bounded
    }
}
