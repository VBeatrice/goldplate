# CHANGELOG

 -  0.1.3 (2021-02-10)
     *  Bump `aeson` dependency upper bound to 1.5.
     *  Bump GHC to 8.10.3.

 -  0.1.2 (2020-11-05)
     *  Bump `regex-pcre-builtin` dependency lower bound to 0.95.1.3 to fix
        issue with `Text` regexes (by Stefano Debenedetti).
     *  Fix issue with `replace` in post process step.  If the string was not
        matched at all, or if there was a remainder, it could get dropped
        (by Stefano Debenedetti).

 -  0.1.1 (2020-06-29)
     *  Add `GOLDPLATE_BASENAME` and `GOLDPLATE_INPUT_BASENAME` environment
        variables.
     *  Fix issue with `GOLDPLATE_FILE` environment variable.

 -  0.1.0 (2020-06-21)
     *  Initial release.
