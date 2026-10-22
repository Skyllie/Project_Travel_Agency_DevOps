package org.project.service.implementation;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.InjectMocks;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;
import org.project.dao.CountryDAO;
import org.project.models.Country;

import java.util.List;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertSame;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

@ExtendWith(MockitoExtension.class)
class CountryServiceImplTest {

    @Mock
    private CountryDAO countryDAO;

    @InjectMocks
    private CountryServiceImpl service;

    @Test
    void getAllCountriesReturnsWhatTheDaoFinds() {
        List<Country> countries = List.of(new Country(), new Country());
        when(countryDAO.getAll()).thenReturn(countries);

        assertSame(countries, service.getAllCountries());
    }

    @Test
    void saveCountryMarksTheNewCountryActual() {
        Country country = new Country();
        country.setName("Ukraine");

        service.saveCountry(country);

        assertTrue(country.isActual());
        verify(countryDAO).save(country);
    }

    @Test
    void updateCountryTakesTheIdFromTheRequestPath() {
        Country country = new Country();
        country.setCountryId(99L);

        service.updateCountry(7L, country);

        assertEquals(Long.valueOf(7L), country.getCountryId());
        verify(countryDAO).update(country);
    }

    @Test
    void deleteCountryDeletesTheCountryFoundById() {
        Country country = new Country();
        when(countryDAO.findById(3L)).thenReturn(country);

        service.deleteCountry(3L);

        verify(countryDAO).delete(country);
    }
}
