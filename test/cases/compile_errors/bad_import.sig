const bogus = @import(
    "bogus-does-not-exist.sig",
);

// error
//
// bogus-does-not-exist.sig:1:1: error: unable to load 'bogus-does-not-exist.sig': FileNotFound
// :2:5: note: file imported here
