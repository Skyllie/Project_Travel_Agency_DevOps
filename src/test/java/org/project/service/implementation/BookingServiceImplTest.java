package org.project.service.implementation;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.project.dao.BookingDAO;
import org.project.dao.RoomDAO;
import org.project.dao.UserDAO;
import org.project.models.Booking;
import org.project.models.Hotel;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyLong;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class BookingServiceImplTest {

    @Mock
    private BookingDAO bookingDAO;

    @Mock
    private RoomDAO roomDAO;

    @Mock
    private UserDAO userDAO;

    @InjectMocks
    private BookingServiceImpl service;

    @Test
    void getAllBookingsLeavesOutBookingsWithoutAHotel() {
        Booking withHotel = new Booking();
        withHotel.setHotel(new Hotel());
        Booking withoutHotel = new Booking();
        when(bookingDAO.getAll()).thenReturn(List.of(withHotel, withoutHotel));

        List<Booking> bookings = service.getAllBookings();

        assertEquals(1, bookings.size());
        assertSame(withHotel, bookings.get(0));
    }

    @Test
    void getAllBookingsByUserIdFailsForAnUnknownUser() {
        when(userDAO.findById(5L)).thenReturn(null);

        RuntimeException error = assertThrows(RuntimeException.class, () -> service.getAllBookingsByUserId(5L));

        assertTrue(error.getMessage().contains("5"));
        verify(bookingDAO, never()).findAllByUser(anyLong());
    }

    @Test
    void saveBookingWithoutRoomMarksTheBookingActual() {
        Booking booking = new Booking();

        service.saveBookingWithoutRoom(booking);

        assertTrue(booking.isActual());
        verify(bookingDAO).save(booking);
    }
}
