package org.project.configuration.security;

import org.junit.jupiter.api.Test;

import java.time.LocalDate;
import java.time.format.DateTimeParseException;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class StringToLocalDateConverterTest {

    private final StringToLocalDateConverter converter = new StringToLocalDateConverter();

    @Test
    void convertsAnIsoDate() {
        assertEquals(LocalDate.of(2026, 10, 22), converter.convert("2026-10-22"));
    }

    @Test
    void rejectsADateInAnotherFormat() {
        assertThrows(DateTimeParseException.class, () -> converter.convert("22.10.2026"));
    }
}
