fn main() -> Result<(), slint::PlatformError> {
    App::new()?.run()
}

slint::slint! {
    export component App inherits Window {
        title: "Howl session";
        width: 800px;
        height: 600px;

        Text {
            text: "Hello World!";
            horizontal-alignment: center;
            vertical-alignment: center;

        }
    }
}
